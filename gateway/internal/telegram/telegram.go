package telegram

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"html"
	"log"
	"math"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"merepoule/gateway/internal/contract"
	"merepoule/gateway/internal/notify"
	"merepoule/gateway/internal/readiness"
	"merepoule/gateway/internal/requests"
	"merepoule/gateway/internal/store"
	"merepoule/gateway/internal/watcher"
)

const (
	pollTimeout    = 25 * time.Second // attente longue de getUpdates
	confirmWindow  = 60 * time.Second // délai pour appuyer sur « Confirmer »
	followUpWithin = 15 * time.Second // attente de la réponse du Watchdog
)

// Config : jeton du bot et chats autorisés. Chats associe un chat à ses
// comptes ; nil = tous les comptes de la passerelle.
type Config struct {
	Token   string
	Chats   map[int64][]int64
	BaseURL string // https://api.telegram.org ; autre valeur pour les tests

	PreAlert float64 // perte en cours qui déclenche la pré-alerte (300) ; 0 = coupée
	CallUser string  // qui appeler par défaut ; sinon le @nom lu dans les messages du chat
	Caller   Caller  // appel vocal (CallMeBot) ; nil = pas d'appel
}

// ParseChats lit "7805445021" ou "7805445021:43204264+123456,-100222".
func ParseChats(s string) (map[int64][]int64, error) {
	chats := map[int64][]int64{}
	for _, item := range strings.Split(s, ",") {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		chatPart, accPart, hasAcc := strings.Cut(item, ":")
		chat, err := strconv.ParseInt(chatPart, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("chat Telegram invalide : %q", chatPart)
		}
		var accounts []int64
		if hasAcc {
			for _, a := range strings.Split(accPart, "+") {
				n, err := strconv.ParseInt(a, 10, 64)
				if err != nil || n <= 0 {
					return nil, fmt.Errorf("compte invalide pour le chat %d : %q", chat, a)
				}
				accounts = append(accounts, n)
			}
		}
		chats[chat] = accounts
	}
	return chats, nil
}

// pendingAction : une commande qui attend son bouton « Confirmer ».
type pendingAction struct {
	kind    string   // kill, relaunch, go ou gosym, repris dans le callback_data du bouton
	symbols []string // gosym : symboles proposés
	chat    int64
	account int64
	expires time.Time
}

// Textes propres à chaque commande confirmée par bouton.
var actions = map[string]struct{ cancelled, command string }{
	"kill":     {"Arrêt annulé", "/kill"},
	"relaunch": {"Relance annulée", "/relancer"},
	"go":       {"Pas maintenant : robot toujours éteint", "/go"},
	"gosym":    {"Pas maintenant : ces symboles restent éteints", "/relancer"},
	"cut":      {"Laisser courir : la Mère surveille", "/etat"},
}

// Bot interroge Telegram en sortie (getUpdates) : aucun port ouvert.
type Bot struct {
	cfg     Config
	watcher *watcher.Watcher
	tracker *requests.Tracker
	client  *http.Client
	now     func() time.Time
	offset  int64

	store *store.Store // attentes du marché ; nil : gardées en mémoire seulement

	mu          sync.Mutex
	pending     map[string]pendingAction    // par jeton de confirmation
	watches     map[int64]*watchState       // par compte : robot éteint, en attente du marché
	preAlerts   map[int64]*preAlert         // par compte : pré-alerte en cours
	prefs       map[int64]map[string]string // sans store : préférences des chats
	reversals   map[string]time.Time        // "compte|symbole" : dernière alerte de retournement
	noAutoWatch map[int64]bool              // /annuler : pas d'attente automatique avant que tout tourne
	comparing   map[int64]bool              // comparatif des règles en cours, par compte
}

// New relit les attentes du marché enregistrées : un redémarrage de la
// passerelle ne les perd pas.
func New(cfg Config, w *watcher.Watcher, tr *requests.Tracker, st *store.Store) *Bot {
	if cfg.BaseURL == "" {
		cfg.BaseURL = "https://api.telegram.org"
	}
	b := &Bot{cfg: cfg, watcher: w, tracker: tr, store: st, now: time.Now,
		client:  &http.Client{Timeout: pollTimeout + 10*time.Second},
		pending: map[string]pendingAction{}, watches: map[int64]*watchState{},
		preAlerts: map[int64]*preAlert{}, prefs: map[int64]map[string]string{},
		reversals: map[string]time.Time{}, noAutoWatch: map[int64]bool{}, comparing: map[int64]bool{}}
	if st != nil {
		saved, err := st.Watches()
		if err != nil {
			log.Printf("telegram: attentes du marché illisibles : %v", err)
		}
		for _, sw := range saved {
			b.watches[sw.Account] = &watchState{Watch: sw}
		}
	}
	return b
}

// Run écarte l'arriéré (un /kill envoyé pendant un arrêt de la passerelle ne
// doit pas partir des heures plus tard), puis traite les messages au fil de l'eau.
func (b *Bot) Run(ctx context.Context) {
	b.call(ctx, "setMyCommands", map[string]any{"commands": []map[string]string{
		{"command": "etat", "description": "État et marché de chaque compte"},
		{"command": "kill", "description": "Arrêt d'urgence, avec confirmation"},
		{"command": "relancer", "description": "Réarmer, robot éteint, et attendre un marché favorable"},
		{"command": "go", "description": "Go-to-market : démarrer le robot maintenant"},
		{"command": "annuler", "description": "Arrêter l'attente du marché"},
		{"command": "actus", "description": "L'Actus du marché, en mots simples (off / on)"},
		{"command": "appel", "description": "Appel d'alerte : qui est appelé, test, off / on"},
		{"command": "regles", "description": "La règle de chaque symbole : tendance, saut, les deux ou aucune"},
		{"command": "comparatif", "description": "Ce qu'aurait donné chaque règle sur 30 jours"},
		{"command": "pret", "description": "L'ordinateur peut-il veiller 24 h sur 24 ?"},
	}})
	go b.watchLoop(ctx)
	go b.actusLoop(ctx)
	go b.preAlertLoop(ctx)
	go b.comparatifLoop(ctx)
	if ups, err := b.getUpdates(ctx, -1, 0); err == nil && len(ups) > 0 {
		b.offset = ups[len(ups)-1].UpdateID + 1
	}
	for ctx.Err() == nil {
		if err := b.Poll(ctx, pollTimeout); err != nil && ctx.Err() == nil {
			log.Printf("telegram: %v", err)
			select {
			case <-ctx.Done():
			case <-time.After(5 * time.Second):
			}
		}
	}
}

// Poll lit un lot de mises à jour et les traite.
func (b *Bot) Poll(ctx context.Context, wait time.Duration) error {
	ups, err := b.getUpdates(ctx, b.offset, wait)
	if err != nil {
		return err
	}
	for _, u := range ups {
		b.offset = u.UpdateID + 1
		switch {
		case u.Message != nil:
			b.onMessage(ctx, u.Message)
		case u.Callback != nil:
			b.onCallback(ctx, u.Callback)
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Commandes

func (b *Bot) allowed(chat int64) ([]int64, bool) {
	accounts, ok := b.cfg.Chats[chat]
	return accounts, ok
}

// accounts : comptes connus de la passerelle que ce chat peut voir.
func (b *Bot) accounts(chat int64) []int64 {
	limit, _ := b.allowed(chat)
	var out []int64
	for _, a := range b.watcher.Accounts() {
		if limit == nil || slices.Contains(limit, a) {
			out = append(out, a)
		}
	}
	return out
}

func (b *Bot) onMessage(ctx context.Context, m *message) {
	chat := m.Chat.ID
	if _, ok := b.allowed(chat); !ok {
		log.Printf("telegram: message du chat %d refusé (non autorisé)", chat)
		b.send(ctx, chat, fmt.Sprintf("&#x26D4; <b>Chat non autorisé</b>\nIdentifiant de ce chat : <code>%d</code>", chat), nil)
		return
	}
	if m.From != nil && m.From.Username != "" && chat > 0 && b.pref(chat, "call_user") == "" {
		b.setPref(chat, "call_user", "@"+m.From.Username) // qui appeler : appris du chat privé
	}
	fields := strings.Fields(m.Text)
	if len(fields) == 0 {
		return
	}
	cmd := strings.ToLower(strings.SplitN(fields[0], "@", 2)[0]) // /kill@MerePouleBot
	switch cmd {
	case "/kill", "/stop":
		b.askKill(ctx, chat, fields[1:])
	case "/relancer", "/relance", "/restart":
		b.askRelaunch(ctx, chat, fields[1:])
	case "/go", "/demarrer":
		b.askGo(ctx, chat, fields[1:])
	case "/annuler":
		b.cancelWatch(ctx, chat, fields[1:])
	case "/actus", "/news", "/marche":
		b.actusCommand(ctx, chat, fields[1:])
	case "/appel", "/call":
		b.callCommand(ctx, chat, fields[1:])
	case "/regles", "/regle", "/rules":
		b.rulesCommand(ctx, chat, fields[1:])
	case "/comparatif", "/compare":
		b.comparatifCommand(ctx, chat, fields[1:])
	case "/etat", "/status":
		b.status(ctx, chat)
	case "/pret", "/ready":
		b.send(ctx, chat, ReadinessMessage(readiness.Run()), nil)
	default:
		b.help(ctx, chat)
	}
}

func (b *Bot) help(ctx context.Context, chat int64) {
	b.send(ctx, chat, "&#x1F425; <b>MerePoule</b>\n"+
		"/etat : état et marché de chaque compte\n"+
		"/kill : arrêt d'urgence, avec confirmation\n"+
		"/relancer : après un arrêt, réarmer ; robot éteint, la Mère attend un marché favorable et propose un go-to-market\n"+
		"/go : go-to-market, démarrer le robot maintenant\n"+
		"/annuler : arrêter l'attente du marché\n"+
		"/actus : l'Actus du marché, en mots simples ; publiée toutes les 30 min (/actus off pour la couper)\n"+
		"/appel : l'appel d'alerte quand la perte en cours atteint -300 (test, off / on)\n"+
		"/regles : la règle de chaque symbole (tendance, saut, les deux ou aucune), et la changer\n"+
		"/comparatif : ce qu'aurait donné chaque règle sur 30 jours ; publié chaque jour à 21:05 GMT\n"+
		"/pret : l'ordinateur peut-il veiller 24 h sur 24 ?\n"+
		"<i>Plusieurs comptes : ajouter le numéro, ex. /kill 43204264.</i>\n\n"+
		"<i>Seuils et réglages du robot : depuis l'app seulement.</i>", nil)
}

// status : /etat, l'état de chaque compte en langage simple.
func (b *Bot) status(ctx context.Context, chat int64) {
	accounts := b.accounts(chat)
	if len(accounts) == 0 {
		b.send(ctx, chat, "&#x26A0;&#xFE0F; <b>Aucun compte</b>\nLa Mère ne donne de nouvelles d'aucun compte.", nil)
		return
	}
	var sb strings.Builder
	now := b.now()
	for i, a := range accounts {
		snap, _ := b.watcher.Snapshot(a)
		st := snap.Status
		if i > 0 {
			sb.WriteString("\n\n")
		}
		fmt.Fprintf(&sb, "<b>%s</b>\n", html.EscapeString(label(a, st.Label)))
		age := notify.Duration(now.Sub(st.TS))
		if st.Stale(now) {
			fmt.Fprintf(&sb, "&#x26A0;&#xFE0F; <b>La Mère ne répond plus</b> : dernières nouvelles il y a %s. "+
				"Vérifier que l'ordinateur est allumé et que MT5 tourne.", age)
			continue
		}
		sb.WriteString(b.robotStatus(a, st))
		fmt.Fprintf(&sb, "\nSolde %s", amount(st.Balance))
		if total := st.Shield.Protected + st.Shield.Unprotected; st.Positions > 0 && total > 0 {
			fmt.Fprintf(&sb, " &#183; filet de sécurité sur %d/%d position(s)", st.Shield.Protected, total)
		}
		for _, m := range st.Market {
			sb.WriteString("\n" + plainLine(m))
			if r := ruleLine(m, hasPositions(st, m.Symbol)); r != "" {
				sb.WriteString("\n" + r)
			}
		}
		if r := ruleMissing(st); r != "" {
			sb.WriteString("\n" + r)
		}
		if c := st.Chameleon; c.Mode != "" {
			sb.WriteString("\n&#x1F98E; Caméléon (essai, ne ferme rien)")
			if len(c.Open) > 0 {
				fmt.Fprintf(&sb, " : suit %d groupe(s) en difficulté", len(c.Open))
			}
			if c.Episodes > 0 {
				verb := "épargné"
				if c.SavedTotal < 0 {
					verb = "coûté"
				}
				fmt.Fprintf(&sb, " &#183; %d bilan(s) : couper aurait %s %s", c.Episodes, verb, amount(math.Abs(c.SavedTotal)))
			}
		}
		fmt.Fprintf(&sb, "\n<i>Nouvelles d'il y a %s</i>", age)
	}
	b.send(ctx, chat, sb.String(), nil)
}

func label(account int64, l string) string {
	if l == "" {
		return strconv.FormatInt(account, 10)
	}
	return l + " " + strconv.FormatInt(account, 10)
}

// marketLines : une ligne simple par symbole du robot.
func marketLines(ms []contract.Market) string {
	lines := make([]string, 0, len(ms))
	for _, m := range ms {
		lines = append(lines, plainLine(m))
	}
	return strings.Join(lines, "\n")
}

// pickAccount résout le compte visé par une commande : celui donné en
// argument, sinon le seul compte du chat. Plusieurs comptes : la liste est
// proposée et ok = false.
func (b *Bot) pickAccount(ctx context.Context, chat int64, command string, args []string) (account int64, ok bool) {
	accounts := b.accounts(chat)
	switch {
	case len(args) > 0:
		n, err := strconv.ParseInt(args[0], 10, 64)
		if err != nil || !slices.Contains(accounts, n) {
			b.send(ctx, chat, fmt.Sprintf("&#x26D4; <b>Compte inconnu ou non autorisé</b> : %s", html.EscapeString(args[0])), nil)
			return 0, false
		}
		return n, true
	case len(accounts) == 1:
		return accounts[0], true
	case len(accounts) == 0:
		b.send(ctx, chat, "&#x26A0;&#xFE0F; <b>Aucun compte</b>\nAucun Watchdog lu par la passerelle.", nil)
		return 0, false
	}
	list := make([]string, len(accounts))
	for i, a := range accounts {
		list[i] = command + " " + strconv.FormatInt(a, 10)
	}
	b.send(ctx, chat, "<b>Quel compte ?</b>\n"+strings.Join(list, "\n"), nil)
	return 0, false
}

// hold met une commande en attente de son bouton et renvoie le jeton.
func (b *Bot) hold(kind string, chat, account int64, valid time.Duration) string {
	token := newToken()
	b.mu.Lock()
	b.pending[token] = pendingAction{kind: kind, chat: chat, account: account, expires: b.now().Add(valid)}
	b.mu.Unlock()
	return token
}

func confirmKeyboard(button, kind, token string) map[string]any {
	return map[string]any{"inline_keyboard": [][]map[string]string{{
		{"text": button, "callback_data": kind + ":" + token},
		{"text": "Annuler", "callback_data": "cancel:" + token},
	}}}
}

// askKill demande une confirmation par bouton : un /kill tapé par erreur ne
// met pas le compte à plat.
func (b *Bot) askKill(ctx context.Context, chat int64, args []string) {
	account, ok := b.pickAccount(ctx, chat, "/kill", args)
	if !ok {
		return
	}

	snap, _ := b.watcher.Snapshot(account)
	if !snap.Status.Stale(b.now()) && snap.Status.State == "KILL" {
		b.send(ctx, chat, fmt.Sprintf("&#x1F6D1; <b>Déjà arrêté</b> &#183; %s\nLe robot est éteint et le compte n'a plus de position.",
			html.EscapeString(label(account, snap.Status.Label))), nil)
		return
	}

	token := b.hold("kill", chat, account, confirmWindow)
	text := fmt.Sprintf("&#x1F6D1; <b>Confirmer l'arrêt d'urgence ?</b>\n%s : %d position(s), résultat en cours %s\n"+
		"La Mère éteindra le robot et fermera toutes ses positions.\n<i>Valable 60 s.</i>",
		html.EscapeString(label(account, snap.Status.Label)), snap.Status.Positions, money(snap.Status.Floating))
	b.send(ctx, chat, text, confirmKeyboard("🛑 Confirmer l'arrêt", "kill", token))
}

// relaunchPlan dit s'il faut réarmer d'abord (KILL) avant de pouvoir rouvrir
// le robot, ou pourquoi c'est impossible. Les refus
// devancent ceux du Watchdog, pour répondre avant de déposer quoi que ce soit.
func relaunchPlan(st contract.Status, now time.Time) (reset bool, refusal string) {
	switch {
	case st.Stale(now):
		return false, "La Mère ne répond plus : pas de relance sans ses nouvelles. Vérifier que l'ordinateur est allumé et que MT5 tourne."
	case st.State == "RUN" && st.FullyRunning():
		return false, "Le robot tourne déjà."
	case st.SavedCharts == 0:
		return false, "La Mère n'a gardé aucun graphique du robot : le relancer à la main dans MT5."
	case st.State != "KILL":
		return false, ""
	case st.Positions > 0 || st.PendingOrders > 0:
		return false, fmt.Sprintf("%d position(s) et %d ordre(s) sont encore ouverts : les fermer d'abord.", st.Positions, st.PendingOrders)
	case st.Config.MaxDailyDDPct > 0 && st.DailyDDPct >= st.Config.MaxDailyDDPct:
		return false, fmt.Sprintf("La perte du jour (%.2f %%) a déjà atteint la limite (%.2f %%) : la Mère recouperait aussitôt. "+
			"Attendre demain, ou relever la limite depuis l'app.", st.DailyDDPct, st.Config.MaxDailyDDPct)
	}
	return true, ""
}

// askRelaunch montre l'arrêt et le marché, puis attend le bouton. Confirmé,
// la Mère réarme mais laisse le robot éteint : il ne démarre que sur un
// go-to-market (décision 20).
func (b *Bot) askRelaunch(ctx context.Context, chat int64, args []string) {
	account, ok := b.pickAccount(ctx, chat, "/relancer", args)
	if !ok {
		return
	}
	snap, _ := b.watcher.Snapshot(account)
	st := snap.Status
	name := html.EscapeString(label(account, st.Label))
	if w, ok := b.watching(account); ok {
		b.send(ctx, chat, fmt.Sprintf("&#x23F3; <b>Déjà en attente du marché</b> &#183; %s &#183; depuis %s\n\n%s\n\n"+
			"<i>/go : démarrer maintenant &#183; /annuler : arrêter l'attente</i>", name, gmt(w.Since), marketBlock(st)), nil)
		return
	}
	reset, refusal := relaunchPlan(st, b.now())
	if refusal != "" {
		b.send(ctx, chat, fmt.Sprintf("&#x26D4; <b>Relance impossible</b> &#183; %s\n%s", name, html.EscapeString(refusal)), nil)
		return
	}

	var sb strings.Builder
	fmt.Fprintf(&sb, "&#x25B6;&#xFE0F; <b>Relancer le robot ?</b>\n%s &#183; %s\n", name, html.EscapeString(st.State))
	if st.State == "KILL" && st.LastKill.At != nil {
		at := st.LastKill.At.UTC()
		fmt.Fprintf(&sb, "Arrêt le %s à %s GMT", at.Format("02/01"), at.Format("15:04"))
		if st.LastKill.Reason != nil {
			fmt.Fprintf(&sb, " : %s", html.EscapeString(*st.LastKill.Reason))
		}
		sb.WriteString("\n")
	}
	fmt.Fprintf(&sb, "Solde %s &#183; %d position(s)\n\n", amount(st.Balance), st.Positions)
	sb.WriteString(marketView(st) + "\n\n")
	button := "▶️ Attendre le marché"
	if reset {
		button = "▶️ Réarmer et attendre le marché"
		sb.WriteString("La Mère réarmera la surveillance, ")
	} else {
		sb.WriteString("La Mère ")
	}
	if perSymbol(st) {
		sb.WriteString("laissera le robot éteint et proposera de démarrer chaque symbole dès que ta règle y passe au &#x1F7E2;. " +
			"Le robot ne démarre que sur ton bouton.")
	} else {
		fmt.Fprintf(&sb, "laissera le robot éteint et proposera un go-to-market quand le marché sera resté favorable %d min. "+
			"Le robot (%d graphique(s)) ne démarre que sur le bouton.", int(favorableHold.Minutes()), st.SavedCharts)
	}
	if until := st.PausedUntil(b.now()); !until.IsZero() {
		sb.WriteString("\n&#x23F8;&#xFE0F; Pause après l'arrêt : pas de démarrage avant " + gmt(until) + ".")
	}
	sb.WriteString("\n<i>Valable 60 s.</i>")
	b.send(ctx, chat, sb.String(), confirmKeyboard(button, "relaunch", b.hold("relaunch", chat, account, confirmWindow)))
}

func (b *Bot) onCallback(ctx context.Context, cq *callbackQuery) {
	b.call(ctx, "answerCallbackQuery", map[string]any{"callback_query_id": cq.ID})
	if cq.Message == nil {
		return
	}
	chat, msgID := cq.Message.Chat.ID, cq.Message.MessageID
	if _, ok := b.allowed(chat); !ok {
		return
	}
	action, token, _ := strings.Cut(cq.Data, ":")
	if action == "seen" || action == "stop" {
		b.preAlertButton(ctx, chat, msgID, action, token)
		return
	}
	if action == "rpick" || action == "rmode" {
		b.rulesButton(ctx, chat, msgID, action, token)
		return
	}
	if action == "gosym" {
		tok, pick, _ := strings.Cut(token, ":")
		b.goSymbolsButton(ctx, chat, msgID, tok, pick)
		return
	}

	b.mu.Lock()
	p, ok := b.pending[token]
	delete(b.pending, token)
	b.mu.Unlock()

	switch {
	case !ok || p.chat != chat || (action != "cancel" && action != p.kind):
		b.edit(ctx, chat, msgID, "&#x26D4; <b>Demande inconnue ou déjà traitée</b>")
	case action == "cancel":
		text := "&#x21A9;&#xFE0F; <b>" + actions[p.kind].cancelled + "</b>"
		if _, watching := b.watching(p.account); watching && (p.kind == "go" || p.kind == "gosym") {
			text += fmt.Sprintf("\nLa Mère continue de surveiller et reproposera dans %d min si le marché reste favorable.",
				int(reproposeAfter.Minutes()))
		}
		b.edit(ctx, chat, msgID, text)
	case b.now().After(p.expires):
		b.edit(ctx, chat, msgID, "&#x231B; <b>Confirmation expirée</b>\nRenvoyer "+actions[p.kind].command+" si c'est toujours voulu.")
	case p.kind == "kill":
		b.kill(ctx, chat, msgID, p.account)
	case p.kind == "relaunch":
		b.relaunch(ctx, chat, msgID, p.account)
	case p.kind == "go":
		b.goMarket(ctx, chat, msgID, p.account)
	case p.kind == "cut" && len(p.symbols) == 1:
		b.cutSymbol(ctx, chat, msgID, p.account, p.symbols[0])
	}
}

func (b *Bot) kill(ctx context.Context, chat int64, msgID, account int64) {
	req, _, err := b.tracker.Submit(account, requests.Kill, "", "telegram:"+strconv.FormatInt(chat, 10), "telegram", nil)
	if err != nil {
		b.edit(ctx, chat, msgID, "&#x26D4; <b>Arrêt NON demandé</b>\n"+html.EscapeString(err.Error()))
		return
	}
	b.edit(ctx, chat, msgID, fmt.Sprintf("&#x23F3; <b>Arrêt demandé</b>\nLa Mère s'en occupe (compte %d).", account))
	go b.followUp(context.WithoutCancel(ctx), chat, req.ID)
}

// await attend l'issue d'une demande ; ok = false si le Watchdog n'a pas
// répondu sous followUpWithin.
func (b *Bot) await(id string) (r store.Request, ok bool) {
	deadline := b.now().Add(followUpWithin)
	for b.now().Before(deadline) {
		r, err := b.tracker.Get(id)
		if err == nil && r.State != requests.Pending {
			return r, r.State != requests.Timeout
		}
		time.Sleep(500 * time.Millisecond)
	}
	return r, false
}

const noAnswer = "&#x26A0;&#xFE0F; <b>La Mère n'a pas répondu en 15 s</b>\n" +
	"La demande l'attend sur l'ordinateur : vérifier qu'il est allumé et que MT5 tourne."

// followUp attend l'issue de l'arrêt et la rapporte dans le chat.
func (b *Bot) followUp(ctx context.Context, chat int64, id string) {
	r, ok := b.await(id)
	switch {
	case !ok:
		b.send(ctx, chat, noAnswer, nil)
	case r.State == requests.Executed:
		b.send(ctx, chat, "&#x2705; <b>Arrêt fait par la Mère</b>\n"+html.EscapeString(r.Detail), nil)
	default:
		b.send(ctx, chat, "&#x26D4; <b>Arrêt refusé</b>\n"+html.EscapeString(r.Detail), nil)
	}
}

// Broadcast envoie un message à tous les chats autorisés.
func (b *Bot) Broadcast(ctx context.Context, text string) {
	for chat := range b.cfg.Chats {
		b.send(ctx, chat, text, nil)
	}
}

// points : « 1 point », « 2 points ».
func points(n int) string {
	if n > 1 {
		return fmt.Sprintf("%d points", n)
	}
	return fmt.Sprintf("%d point", n)
}

// ReadinessMessage met en forme le diagnostic « Prêt pour le 24 h » en
// langage simple : ce qui se passe, que faire, puis ce qui est déjà en ordre.
// Les commandes techniques restent dans une ligne « Pour les initiés ».
func ReadinessMessage(r readiness.Report) string {
	errs, warns := r.Problems()
	var fine []string
	for _, c := range r.Checks {
		if c.Level == readiness.OK {
			fine = append(fine, html.EscapeString(c.Label))
		}
	}
	if errs+warns == 0 {
		return "&#x2705; <b>L'ordinateur est prêt à veiller 24 h sur 24</b>\n" +
			"Il reste éveillé et branché, redémarre sans mot de passe, et relance tout seul MT5 et MerePoule.\n\n" +
			"<i>Vérifié : " + strings.Join(fine, ", ") + ".</i>"
	}

	var sb strings.Builder
	fmt.Fprintf(&sb, "&#x1FA7A; <b>L'ordinateur peut-il veiller 24 h sur 24 ?</b>\n")
	switch {
	case errs > 0 && warns > 0:
		fmt.Fprintf(&sb, "Pas encore : %s à corriger, %s à surveiller.", points(errs), points(warns))
	case errs > 0:
		fmt.Fprintf(&sb, "Pas encore : %s à corriger.", points(errs))
	default:
		fmt.Fprintf(&sb, "Oui, avec %s à surveiller.", points(warns))
	}
	sb.WriteString("\n<i>La Mère ne protège le compte que si l'ordinateur reste allumé, éveillé et connecté.</i>")

	for _, level := range []string{readiness.Error, readiness.Warning} {
		for _, c := range r.Checks {
			if c.Level != level {
				continue
			}
			mark, what := "&#x26A0;&#xFE0F;", "à surveiller"
			if level == readiness.Error {
				mark, what = "&#x274C;", "à corriger"
			}
			fmt.Fprintf(&sb, "\n\n%s <b>%s</b> &#183; %s\n%s", mark, html.EscapeString(c.Label), what, html.EscapeString(c.Detail))
			if c.Fix != "" {
				fmt.Fprintf(&sb, "\n&#x1F449; <b>Que faire :</b> %s", html.EscapeString(c.Fix))
			}
			if c.Tech != "" {
				fmt.Fprintf(&sb, "\n<i>Pour les initiés :</i> <code>%s</code>", html.EscapeString(c.Tech))
			}
		}
	}
	if len(fine) > 0 {
		sb.WriteString("\n\n&#x2705; <b>Déjà en ordre :</b> " + strings.Join(fine, ", ") + ".")
	}
	return sb.String()
}

func newToken() string {
	buf := make([]byte, 8)
	rand.Read(buf)
	return hex.EncodeToString(buf)
}

// ---------------------------------------------------------------------------
// API Telegram

type chatRef struct {
	ID int64 `json:"id"`
}

type userRef struct {
	ID       int64  `json:"id"`
	Username string `json:"username"`
}

type message struct {
	MessageID int64    `json:"message_id"`
	Chat      chatRef  `json:"chat"`
	From      *userRef `json:"from"`
	Text      string   `json:"text"`
}

type callbackQuery struct {
	ID      string   `json:"id"`
	Data    string   `json:"data"`
	Message *message `json:"message"`
}

type update struct {
	UpdateID int64          `json:"update_id"`
	Message  *message       `json:"message"`
	Callback *callbackQuery `json:"callback_query"`
}

func (b *Bot) getUpdates(ctx context.Context, offset int64, wait time.Duration) ([]update, error) {
	q := url.Values{}
	q.Set("offset", strconv.FormatInt(offset, 10))
	q.Set("timeout", strconv.Itoa(int(wait/time.Second)))
	q.Set("allowed_updates", `["message","callback_query"]`)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, b.cfg.BaseURL+"/bot"+b.cfg.Token+"/getUpdates?"+q.Encode(), nil)
	if err != nil {
		return nil, err
	}
	var out struct {
		OK          bool     `json:"ok"`
		Description string   `json:"description"`
		Result      []update `json:"result"`
	}
	if err := b.do(req, &out); err != nil {
		return nil, err
	}
	if !out.OK {
		return nil, fmt.Errorf("getUpdates : %s", out.Description)
	}
	return out.Result, nil
}

func (b *Bot) send(ctx context.Context, chat int64, text string, markup any) {
	body := map[string]any{"chat_id": chat, "text": text, "parse_mode": "HTML", "disable_web_page_preview": true}
	if markup != nil {
		body["reply_markup"] = markup
	}
	b.call(ctx, "sendMessage", body)
}

func (b *Bot) edit(ctx context.Context, chat, msgID int64, text string) {
	b.call(ctx, "editMessageText", map[string]any{"chat_id": chat, "message_id": msgID, "text": text, "parse_mode": "HTML"})
}

func (b *Bot) call(ctx context.Context, method string, body map[string]any) {
	raw, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, b.cfg.BaseURL+"/bot"+b.cfg.Token+"/"+method, bytes.NewReader(raw))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	var out struct {
		OK          bool   `json:"ok"`
		Description string `json:"description"`
	}
	if err := b.do(req, &out); err != nil || !out.OK {
		log.Printf("telegram: %s : %v %s", method, err, out.Description) // jamais l'URL : elle contient le jeton
	}
}

func (b *Bot) do(req *http.Request, out any) error {
	res, err := b.client.Do(req)
	if err != nil {
		// L'erreur de net/http cite l'URL, donc le jeton : on ne garde que la cause.
		if ue, ok := err.(*url.Error); ok {
			return ue.Err
		}
		return err
	}
	defer res.Body.Close()
	return json.NewDecoder(res.Body).Decode(out)
}
