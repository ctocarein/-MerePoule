package telegram

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"merepoule/gateway/internal/contract"
	"merepoule/gateway/internal/flags"
	"merepoule/gateway/internal/requests"
)

// Le comparatif des règles (décision 30). Un service MT5 à part, le Lecteur,
// rejoue 30 jours d'historique avec la règle tendance, la règle saut, les
// deux, ou aucune, symbole par symbole : sur le marché (une entrée comme le
// robot toutes les 5 min, tenue jusqu'au saut suivant) et sur les vrais
// trades du robot. La passerelle le lui demande (compare.flag), attend
// lecteur.json, puis propose la meilleure règle avec un bouton : rien ne
// change sans le trader.
const (
	compareDays    = 30
	defaultLateMin = 40
	comparatifAt   = 21*time.Hour + 5*time.Minute // chaque jour, après le changement de jour du courtier (21:00 GMT)
	rulesValid     = time.Hour                    // boutons de choix de règle
)

// Variables pour les tests.
var (
	lecteurPoll = 2 * time.Second
	lecteurWait = 3 * time.Minute
)

var modePlain = map[string]string{"trend": "tendance", "jump": "saut", "both": "tendance et saut", "none": "aucune"}

var modeButton = map[string]string{"trend": "Tendance", "jump": "Saut", "both": "Les deux", "none": "Aucune"}

const modesHelp = "<i>Tendance : M5, et M30 ou H1, dans le sens du robot. Saut : pause quand aucun saut n'est venu depuis %d min. " +
	"Les deux : il faut les deux. Aucune : pas de filtre, seules les protections sur les pertes jouent.</i>"

const lecteurMissing = "&#x26A0;&#xFE0F; <b>Le Lecteur n'a pas répondu</b> &#183; %s\n" +
	"Il faut l'ajouter une fois dans MT5 : <b>Navigateur</b>, <b>Services</b>, clic droit, <b>Ajouter un service</b>, " +
	"<b>MerePouleLecteur</b>. Il redémarre ensuite tout seul avec MT5.\n<i>Il ne trade pas : il relit seulement l'historique.</i>"

const lecteurSlow = "&#x23F3; <b>Le Lecteur n'a pas fini</b> &#183; %s\nIl a pris la demande mais n'a pas encore répondu : " +
	"historique long à charger. Réessayer /comparatif dans quelques minutes."

// lateMin : la règle saut du Watchdog ; 40 min avant la version 1.34.
func lateMin(st contract.Status) int {
	if st.Config.JumpLateMin > 0 {
		return st.Config.JumpLateMin
	}
	return defaultLateMin
}

// ruleSymbols : les symboles du robot où une règle s'applique.
func ruleSymbols(st contract.Status) []contract.Market {
	var out []contract.Market
	for _, m := range st.Market {
		if m.Want != "" && m.Rule != "" {
			out = append(out, m)
		}
	}
	return out
}

// requestCompare dépose compare.flag pour le Lecteur et renvoie son request_id.
func (b *Bot) requestCompare(account int64) (string, error) {
	snap, _ := b.watcher.Snapshot(account)
	st := snap.Status
	if st.Stale(b.now()) {
		return "", errors.New("La Mère ne répond plus : vérifier que l'ordinateur est allumé et que MT5 tourne.")
	}
	var syms []string
	for _, m := range ruleSymbols(st) {
		syms = append(syms, m.Symbol)
	}
	if len(syms) == 0 {
		return "", errors.New("Aucun symbole du robot à comparer : remettre MerePoule (1.34) sur son graphique dans MT5.")
	}
	id := requests.NewID()
	req := contract.CompareRequest{RequestID: id, Origin: "telegram", Days: compareDays, JumpLateMin: lateMin(st),
		Magic: st.Config.Magic, Symbols: syms}
	if err := flags.Write(b.watcher.Dir(account), contract.CompareFlag, req); err != nil {
		return "", fmt.Errorf("demande non déposée : %w", err)
	}
	return id, nil
}

// awaitLecteur attend le lecteur.json qui répond à id ; taken dit si le
// Lecteur a au moins pris la demande (drapeau supprimé).
func (b *Bot) awaitLecteur(ctx context.Context, account int64, id string) (l contract.Lecteur, ok, taken bool) {
	dir := b.watcher.Dir(account)
	deadline := time.Now().Add(lecteurWait)
	for time.Now().Before(deadline) {
		if raw, err := os.ReadFile(filepath.Join(dir, contract.LecteurFile)); err == nil {
			var got contract.Lecteur
			if json.Unmarshal(raw, &got) == nil && got.RequestID != nil && *got.RequestID == id {
				return got, true, true
			}
		}
		select {
		case <-ctx.Done():
			return l, false, false
		case <-time.After(lecteurPoll):
		}
	}
	return l, false, !flags.Pending(dir, contract.CompareFlag)
}

// startComparatif : un seul comparatif à la fois par compte.
func (b *Bot) startComparatif(account int64) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.comparing[account] {
		return false
	}
	b.comparing[account] = true
	return true
}

func (b *Bot) endComparatif(account int64) {
	b.mu.Lock()
	delete(b.comparing, account)
	b.mu.Unlock()
}

// comparatifCommand : /comparatif, le comparatif des règles à la demande.
func (b *Bot) comparatifCommand(ctx context.Context, chat int64, args []string) {
	account, ok := b.pickAccount(ctx, chat, "/comparatif", args)
	if !ok {
		return
	}
	snap, _ := b.watcher.Snapshot(account)
	name := html.EscapeString(label(account, snap.Status.Label))
	if !b.startComparatif(account) {
		b.send(ctx, chat, "&#x23F3; <b>Comparatif déjà en cours</b> &#183; "+name+"\nLa réponse arrive dans ce chat.", nil)
		return
	}
	id, err := b.requestCompare(account)
	if err != nil {
		b.endComparatif(account)
		b.send(ctx, chat, "&#x26D4; <b>Comparatif impossible</b> &#183; "+name+"\n"+html.EscapeString(err.Error()), nil)
		return
	}
	b.send(ctx, chat, fmt.Sprintf("&#x1F50E; <b>Comparatif demandé</b> &#183; %s\nLe Lecteur relit %d jours de marché et les vrais trades du robot, "+
		"avec la règle tendance, la règle saut, les deux, ou aucune. Réponse dans une ou deux minutes.", name, compareDays), nil)
	go b.deliverComparatif(context.WithoutCancel(ctx), []int64{chat}, account, id)
}

// deliverComparatif attend le Lecteur et envoie le comparatif à chaque chat.
func (b *Bot) deliverComparatif(ctx context.Context, chats []int64, account int64, id string) {
	defer b.endComparatif(account)
	l, ok, taken := b.awaitLecteur(ctx, account, id)
	snap, _ := b.watcher.Snapshot(account)
	name := html.EscapeString(label(account, snap.Status.Label))
	for _, chat := range chats {
		switch {
		case ok:
			text, markup := b.comparatifText(chat, account, snap.Status, l)
			b.send(ctx, chat, text, markup)
		case taken:
			b.send(ctx, chat, fmt.Sprintf(lecteurSlow, name), nil)
		default:
			b.send(ctx, chat, fmt.Sprintf(lecteurMissing, name), nil)
		}
	}
}

// whole : "+9779", sans décimales.
func whole(v float64) string { return fmt.Sprintf("%+.0f", v) }

// share : part des entrées qu'une règle laisse passer, en %.
func share(t, all contract.LecteurTally) int {
	if all.N == 0 {
		return 0
	}
	return int(float64(t.N)*100/float64(all.N) + 0.5)
}

// comparatifText met en forme le comparatif et ses boutons : un par symbole
// dont la meilleure règle n'est pas celle choisie.
func (b *Bot) comparatifText(chat, account int64, st contract.Status, l contract.Lecteur) (string, any) {
	var sb strings.Builder
	fmt.Fprintf(&sb, "&#x1F50E; <b>Comparatif des règles</b> &#183; %s\n<i>%d derniers jours &#183; marché : une entrée comme le robot "+
		"toutes les 5 min, gardée jusqu'au saut suivant &#183; « allumé » : part du temps où la règle laisse tourner le robot</i>",
		html.EscapeString(label(account, st.Label)), l.Days)
	if l.Error != "" {
		fmt.Fprintf(&sb, "\n\n&#x26A0;&#xFE0F; Le Lecteur n'a rien pu comparer : %s", html.EscapeString(l.Error))
		return sb.String(), nil
	}
	var picks []string // "symbole|règle" des boutons
	for _, s := range l.Symbols {
		short := html.EscapeString(shortName(s.Symbol))
		if s.Error != "" {
			fmt.Fprintf(&sb, "\n\n&#x26A0;&#xFE0F; <b>%s</b> : %s", short, html.EscapeString(s.Error))
			continue
		}
		m, _ := marketOf(st, s.Symbol)
		current := m.RuleMode
		fmt.Fprintf(&sb, "\n\n<b>%s</b>", short)
		if current != "" {
			fmt.Fprintf(&sb, " &#183; ta règle : %s", modePlain[current])
		}
		fmt.Fprintf(&sb, " &#183; lot %s", strings.Replace(strconv.FormatFloat(s.Lot, 'f', -1, 64), ".", ",", 1))
		all, robot := s.Market["none"], s.Robot["none"].N > 0
		for _, mode := range contract.RuleModes {
			t := s.Market[mode]
			line := fmt.Sprintf("\n&#x2022; %s : marché %s, allumé %d %%", modePlain[mode], whole(t.Total), share(t, all))
			if mode == s.Best {
				line = fmt.Sprintf("\n&#x2022; <b>%s</b> : marché <b>%s</b>, allumé %d %%", modePlain[mode], whole(t.Total), share(t, all))
			}
			if robot {
				r := s.Robot[mode]
				line += fmt.Sprintf(" &#183; vrais trades %s (%d cycle(s))", whole(r.Total), r.N)
			}
			sb.WriteString(line)
		}
		if !robot {
			sb.WriteString("\n<i>Vrais trades : aucun cycle du robot sur la période.</i>")
		}
		by := "d'après le marché"
		if s.BestBy == "robot" {
			by = "d'après les vrais trades du robot"
		}
		switch {
		case current == "":
			fmt.Fprintf(&sb, "\n&#x1F449; Meilleure ici : <b>%s</b> (%s). Pour la choisir, remettre MerePoule (1.34) sur son graphique dans MT5.",
				modePlain[s.Best], by)
		case current == s.Best:
			fmt.Fprintf(&sb, "\n&#x1F449; Meilleure ici : <b>%s</b> (%s) : c'est déjà ta règle.", modePlain[s.Best], by)
		default:
			fmt.Fprintf(&sb, "\n&#x1F449; Meilleure ici : <b>%s</b> (%s).", modePlain[s.Best], by)
			picks = append(picks, s.Symbol+"|"+s.Best)
		}
	}
	fmt.Fprintf(&sb, "\n\n<i>Indicatif : les entrées se chevauchent, et un cycle bloqué aurait décalé les suivants. "+
		"Rien ne change sans ton bouton ; /regles pour choisir autrement.</i>\n"+modesHelp, l.JumpLateMin)
	if len(picks) == 0 {
		return sb.String(), nil
	}
	var syms []string
	var rows [][]map[string]string
	for _, p := range picks {
		sym, _, _ := strings.Cut(p, "|")
		syms = append(syms, sym)
	}
	token := b.holdRules(chat, account, syms)
	for i, p := range picks {
		_, mode, _ := strings.Cut(p, "|")
		rows = append(rows, []map[string]string{{
			"text":          fmt.Sprintf("✅ %s : règle %s", shortName(syms[i]), modePlain[mode]),
			"callback_data": fmt.Sprintf("rmode:%s:%d:%d", token, i, slices.Index(contract.RuleModes, mode)),
		}})
	}
	sb.WriteString("\n<i>Boutons valables 1 h.</i>")
	return sb.String(), map[string]any{"inline_keyboard": rows}
}

// holdRules garde les symboles des boutons de choix de règle ; un bouton
// reste valable 1 h, et plusieurs peuvent servir.
func (b *Bot) holdRules(chat, account int64, symbols []string) string {
	token := newToken()
	now := b.now()
	b.mu.Lock()
	defer b.mu.Unlock()
	for t, p := range b.pending {
		if p.kind == "rules" && now.After(p.expires) {
			delete(b.pending, t)
		}
	}
	b.pending[token] = pendingAction{kind: "rules", chat: chat, account: account, expires: now.Add(rulesValid), symbols: symbols}
	return token
}

// rulesCommand : /regles, la règle de chaque symbole, un bouton pour la changer.
func (b *Bot) rulesCommand(ctx context.Context, chat int64, args []string) {
	account, ok := b.pickAccount(ctx, chat, "/regles", args)
	if !ok {
		return
	}
	snap, _ := b.watcher.Snapshot(account)
	st := snap.Status
	name := html.EscapeString(label(account, st.Label))
	ms := ruleSymbols(st)
	if len(ms) == 0 || st.Stale(b.now()) {
		b.send(ctx, chat, "&#x26D4; <b>Pas de règle à montrer</b> &#183; "+name+"\nLa Mère ne répond plus, ou ne lit pas encore le marché du robot.", nil)
		return
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "&#x1F3AF; <b>Règle par symbole</b> &#183; %s", name)
	var syms []string
	for _, m := range ms {
		mode := m.RuleMode
		if mode == "" {
			mode = "trend"
		}
		fmt.Fprintf(&sb, "\n<b>%s</b> : %s &#183; %s", html.EscapeString(shortName(m.Symbol)), modePlain[mode], verdictIcon(m))
		if m.RuleMode == "jump" || m.RuleMode == "both" {
			sb.WriteString(" (" + jumpText(m.JumpAgeMin) + ")")
		}
		syms = append(syms, m.Symbol)
	}
	sb.WriteString("\n\n" + fmt.Sprintf(modesHelp, lateMin(st)) + "\n<i>/comparatif : ce qu'aurait donné chaque règle sur 30 jours.</i>")
	if ms[0].RuleMode == "" {
		sb.WriteString("\n\n&#x2139;&#xFE0F; Pour choisir une règle par symbole, remettre MerePoule (1.34) sur son graphique dans MT5.")
		b.send(ctx, chat, sb.String(), nil)
		return
	}
	token := b.holdRules(chat, account, syms)
	var rows [][]map[string]string
	for i, s := range syms {
		rows = append(rows, []map[string]string{{"text": "Changer " + shortName(s), "callback_data": fmt.Sprintf("rpick:%s:%d", token, i)}})
	}
	b.send(ctx, chat, sb.String(), map[string]any{"inline_keyboard": rows})
}

// rulesButton : « Changer <symbole> » (rpick) montre les 4 règles ;
// une règle (rmode) la fait appliquer par la Mère.
func (b *Bot) rulesButton(ctx context.Context, chat, msgID int64, action, data string) {
	parts := strings.Split(data, ":")
	b.mu.Lock()
	p, ok := b.pending[parts[0]]
	b.mu.Unlock()
	var sym string
	i := -1
	if len(parts) >= 2 {
		i, _ = strconv.Atoi(parts[1])
	}
	switch {
	case !ok || p.chat != chat || p.kind != "rules" || i < 0 || i >= len(p.symbols):
		b.edit(ctx, chat, msgID, "&#x26D4; <b>Demande inconnue ou déjà traitée</b>")
		return
	case b.now().After(p.expires):
		b.edit(ctx, chat, msgID, "&#x231B; <b>Boutons expirés</b>\n/regles pour choisir de nouveau.")
		return
	}
	sym = p.symbols[i]
	snap, _ := b.watcher.Snapshot(p.account)
	m, _ := marketOf(snap.Status, sym)

	if action == "rpick" {
		var row []map[string]string
		for k, mode := range contract.RuleModes {
			text := modeButton[mode]
			if mode == m.RuleMode {
				text = "✓ " + text
			}
			row = append(row, map[string]string{"text": text, "callback_data": fmt.Sprintf("rmode:%s:%d:%d", parts[0], i, k)})
		}
		b.send(ctx, chat, fmt.Sprintf("&#x1F3AF; <b>Quelle règle pour %s ?</b>\nActuelle : %s.\n"+modesHelp,
			html.EscapeString(shortName(sym)), modePlain[m.RuleMode], lateMin(snap.Status)),
			map[string]any{"inline_keyboard": [][]map[string]string{row[:2], row[2:]}})
		return
	}

	k := -1
	if len(parts) >= 3 {
		k, _ = strconv.Atoi(parts[2])
	}
	if k < 0 || k >= len(contract.RuleModes) {
		b.edit(ctx, chat, msgID, "&#x26D4; <b>Demande inconnue ou déjà traitée</b>")
		return
	}
	mode := contract.RuleModes[k]
	short := html.EscapeString(shortName(sym))
	if m.RuleMode == mode {
		b.send(ctx, chat, fmt.Sprintf("&#x2139;&#xFE0F; <b>%s suit déjà la règle %s</b>", short, modePlain[mode]), nil)
		return
	}
	b.send(ctx, chat, fmt.Sprintf("&#x23F3; <b>Règle %s demandée</b> pour %s", modePlain[mode], short), nil)
	go func(ctx context.Context) {
		if _, ok := b.runStep(ctx, chat, p.account, requests.Rules, "Choix de règle",
			map[string]any{"symbol": sym, "mode": mode, "reason": "choix depuis Telegram"}); !ok {
			return
		}
		b.send(ctx, chat, fmt.Sprintf("&#x2705; <b>Fait</b> : %s suit maintenant la règle %s.", short, modePlain[mode]), nil)
	}(context.WithoutCancel(ctx))
}

// nextComparatif : prochain comparatif quotidien, à 21:05 GMT.
func nextComparatif(now time.Time) time.Time {
	t := now.UTC().Truncate(24 * time.Hour).Add(comparatifAt)
	if !now.Before(t) {
		t = t.Add(24 * time.Hour)
	}
	return t
}

// publishComparatif : le comparatif du jour, pour chaque compte, à ses chats.
func (b *Bot) publishComparatif(ctx context.Context) {
	for _, a := range b.watcher.Accounts() {
		chats := b.chatsFor(a)
		if len(chats) == 0 || !b.startComparatif(a) {
			continue
		}
		id, err := b.requestCompare(a)
		if err != nil {
			b.endComparatif(a)
			log.Printf("telegram: comparatif du compte %d non demandé : %v", a, err)
			continue
		}
		go b.deliverComparatif(ctx, chats, a, id)
	}
}

func (b *Bot) comparatifLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Until(nextComparatif(time.Now()))):
			b.publishComparatif(ctx)
		}
	}
}
