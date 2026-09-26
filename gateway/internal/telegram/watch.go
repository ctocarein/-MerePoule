package telegram

import (
	"context"
	"fmt"
	"html"
	"log"
	"slices"
	"strconv"
	"strings"
	"time"

	"merepoule/gateway/internal/contract"
	"merepoule/gateway/internal/requests"
	"merepoule/gateway/internal/store"
)

// Attente du marché (décision 20). /relancer réarme mais laisse le robot
// éteint, sans position. La Mère lit le marché, en rend compte, et propose un
// go-to-market quand il est resté favorable assez longtemps. Le robot ne
// démarre que sur le bouton : la décision reste humaine.
const (
	watchEvery     = 30 * time.Second
	favorableHold  = 10 * time.Minute // marché favorable d'affilée avant un go-to-market
	proposalValid  = 10 * time.Minute // durée du bouton « Démarrer le robot »
	reproposeAfter = 30 * time.Minute // après « Pas maintenant » ou un bouton expiré
	bulletinEvery  = 2 * time.Hour    // point sur le marché pendant l'attente
	maxWait        = 24 * time.Hour
)

type watchState struct {
	store.Watch
	token    string // go-to-market proposé, en attente de réponse ; "" sinon
	starting bool   // démarrage demandé : c'est son compte rendu qui clôt l'attente

	// Go-to-market par symbole (décision 27), en mémoire seulement.
	symProposed map[string]time.Time // dernière proposition, par symbole
	symTokens   []string             // propositions en attente de réponse
}

// perSymbol : le Watchdog (1.31) donne les symboles gardés et le verdict de
// la règle du trader pour chacun : le go-to-market se fait symbole par symbole.
func perSymbol(st contract.Status) bool {
	if len(st.SavedSymbols) == 0 {
		return false
	}
	for _, s := range st.SavedSymbols {
		if m, ok := marketOf(st, s); !ok || m.Rule == "" {
			return false
		}
	}
	return true
}

func marketOf(st contract.Status, symbol string) (contract.Market, bool) {
	for _, m := range st.Market {
		if m.Symbol == symbol {
			return m, true
		}
	}
	return contract.Market{}, false
}

func names(symbols []string) string {
	out := make([]string, len(symbols))
	for i, s := range symbols {
		out[i] = html.EscapeString(shortName(s))
	}
	return strings.Join(out, ", ")
}

// symbolsBlock : chaque symbole gardé, son marché et le verdict de la règle.
func symbolsBlock(st contract.Status) string {
	var sb strings.Builder
	off := st.OffSymbols()
	for _, s := range st.SavedSymbols {
		m, _ := marketOf(st, s)
		state := "en marche"
		if slices.Contains(off, s) {
			state = "éteint"
		}
		fmt.Fprintf(&sb, "%s <i>(robot %s)</i>\n%s\n", plainLine(m), state, ruleLine(m, false))
	}
	return strings.TrimRight(sb.String(), "\n")
}

// marketView : par symbole avec la règle si le Watchdog la donne, sinon le
// verdict d'ensemble.
func marketView(st contract.Status) string {
	if perSymbol(st) {
		return symbolsBlock(st)
	}
	return marketBlock(st)
}

const favorableRule = "<i>Favorable : aucun symbole ne part nettement contre le robot (ses achats qui baissent, ses ventes " +
	"qui montent), et aucun n'est nerveux. « Nettement » : sur la dernière heure, le prix a bougé plus qu'une demi-bougie H1 habituelle.</i>"

var sideText = map[string]string{"buy": "achats", "sell": "ventes"}

// against : la tendance va-t-elle contre le sens habituel du robot sur ce
// symbole ? Sens inconnu ou mixte : toute tendance forte compte.
func against(m contract.Market) bool {
	trend, _, _ := nowTrend(m)
	switch m.RobotSide {
	case "buy":
		return trend == "baisse"
	case "sell":
		return trend == "hausse"
	}
	return trend == "hausse" || trend == "baisse"
}

// verdict : le marché des symboles du robot permet-il de démarrer ? Marché
// inconnu (Watchdog antérieur à 1.25, historique pas chargé) : non.
func verdict(st contract.Status) (favorable bool, reasons []string) {
	if len(st.Market) == 0 {
		return false, []string{"marché pas encore lu par la Mère (version 1.25 ou plus)"}
	}
	for _, m := range st.Market {
		if against(m) {
			_, chg, span := nowTrend(m)
			reason := fmt.Sprintf("%s %s (%s en %s)", shortName(m.Symbol), moveText(m), pct(chg), span)
			if side, ok := sideText[m.RobotSide]; ok {
				reason += ", contre les " + side + " du robot"
			}
			reasons = append(reasons, reason)
		}
		if m.Volatility == "agite" {
			reasons = append(reasons, shortName(m.Symbol)+" très nerveux, avec de grands écarts")
		}
	}
	return len(reasons) == 0, reasons
}

// marketBlock : le marché symbole par symbole, puis le verdict et ses raisons.
func marketBlock(st contract.Status) string {
	var sb strings.Builder
	if m := marketLines(st.Market); m != "" {
		sb.WriteString("<b>Le marché</b>\n" + m + "\n\n")
	}
	if ok, reasons := verdict(st); ok {
		sb.WriteString("&#x2705; <b>Favorable</b> : rien ne part nettement contre le robot, rien de nerveux.")
	} else {
		sb.WriteString("&#x23F8;&#xFE0F; <b>Pas favorable</b>")
		for _, r := range reasons {
			sb.WriteString("\n- " + html.EscapeString(r))
		}
	}
	return sb.String()
}

func gmt(t time.Time) string { return t.UTC().Format("15:04") + " GMT" }

// watching dit si le compte attend le marché, et depuis quand.
func (b *Bot) watching(account int64) (store.Watch, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	w, ok := b.watches[account]
	if !ok {
		return store.Watch{}, false
	}
	return w.Watch, true
}

// saveWatch : b.mu tenu.
func (b *Bot) saveWatch(w *watchState) {
	if b.store == nil {
		return
	}
	if err := b.store.SaveWatch(w.Watch); err != nil {
		log.Printf("telegram: attente du compte %d non enregistrée : %v", w.Account, err)
	}
}

func (b *Bot) endWatch(account int64) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if w, ok := b.watches[account]; ok && w.token != "" {
		delete(b.pending, w.token)
	}
	delete(b.watches, account)
	if b.store != nil {
		b.store.DeleteWatch(account)
	}
}

// startWatch ouvre l'attente et envoie le premier point sur le marché.
func (b *Bot) startWatch(ctx context.Context, chat, account int64) {
	now := b.now()
	snap, _ := b.watcher.Snapshot(account)
	w := &watchState{Watch: store.Watch{Account: account, Chat: chat, Since: now, BulletinAt: now}}
	if ok, _ := verdict(snap.Status); ok && !snap.Status.Stale(now) {
		w.FavorableSince = now
	}
	b.mu.Lock()
	b.watches[account] = w
	b.saveWatch(w)
	b.mu.Unlock()

	pause := ""
	if until := snap.Status.PausedUntil(now); !until.IsZero() {
		pause = "\n&#x23F8;&#xFE0F; Pause après l'arrêt d'urgence : pas de démarrage avant " + gmt(until) + "."
	}
	if perSymbol(snap.Status) {
		b.send(ctx, chat, fmt.Sprintf("&#x23F3; <b>Robot éteint, en attente de ta règle</b> &#183; %s\n"+
			"La Mère proposera de démarrer chaque symbole dès que ta règle y passe au &#x1F7E2;. "+
			"Les &#x1F534; restent éteints. Le robot ne démarre que sur ton bouton.%s\n\n%s\n\n"+
			"<i>/go : tout démarrer maintenant &#183; /annuler : arrêter l'attente</i>",
			html.EscapeString(label(account, snap.Status.Label)), pause, symbolsBlock(snap.Status)), nil)
		return
	}
	b.send(ctx, chat, fmt.Sprintf("&#x23F3; <b>Robot éteint, en attente du marché</b> &#183; %s\n"+
		"La Mère surveille le marché et proposera un go-to-market quand il sera resté favorable %d min. "+
		"Le robot ne démarre que sur le bouton.%s\n\n%s\n\n%s\n\n<i>/go : démarrer maintenant &#183; /annuler : arrêter l'attente</i>",
		html.EscapeString(label(account, snap.Status.Label)), int(favorableHold.Minutes()), pause, marketBlock(snap.Status), favorableRule), nil)
}

func (b *Bot) watchLoop(ctx context.Context) {
	t := time.NewTicker(watchEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			b.tickWatches(ctx)
		}
	}
}

// autoWatch : en mode par symbole, un compte en marche dont des symboles
// sont éteints (pause à plat, coupe) attend leur passage au 🟢 sans
// /relancer. Silencieux : le Watchdog a déjà annoncé la pause ou la coupe.
func (b *Bot) autoWatch() {
	now := b.now()
	for _, a := range b.watcher.Accounts() {
		snap, _ := b.watcher.Snapshot(a)
		st := snap.Status
		if st.Stale(now) || st.State != "RUN" || !perSymbol(st) {
			continue
		}
		chats := b.chatsFor(a)
		b.mu.Lock()
		switch {
		case len(st.OffSymbols()) == 0:
			delete(b.noAutoWatch, a)
		case b.watches[a] == nil && !b.noAutoWatch[a] && len(chats) > 0:
			w := &watchState{Watch: store.Watch{Account: a, Chat: chats[0], Since: now, BulletinAt: now}}
			b.watches[a] = w
			b.saveWatch(w)
		}
		b.mu.Unlock()
	}
}

func (b *Bot) tickWatches(ctx context.Context) {
	b.autoWatch()
	b.mu.Lock()
	accounts := make([]int64, 0, len(b.watches))
	for a := range b.watches {
		accounts = append(accounts, a)
	}
	b.mu.Unlock()
	slices.Sort(accounts)
	for _, a := range accounts {
		b.tickWatch(ctx, a)
	}
}

// tickWatch fait avancer une attente : fin, retrait ou proposition d'un
// go-to-market, point périodique. Les messages partent après le verrou.
func (b *Bot) tickWatch(ctx context.Context, account int64) {
	now := b.now()
	snap, _ := b.watcher.Snapshot(account)
	st := snap.Status
	name := html.EscapeString(label(account, st.Label))

	var text string
	var markup any
	b.mu.Lock()
	w, ok := b.watches[account]
	if !ok || w.starting {
		b.mu.Unlock()
		return
	}
	chat := w.Chat
	ended := false
	if w.token != "" {
		if p, ok := b.pending[w.token]; !ok || now.After(p.expires) {
			delete(b.pending, w.token) // répondu « Pas maintenant », ou expiré
			w.token = ""
		}
	}

	per := perSymbol(st)
	switch {
	case st.Stale(now):
		w.FavorableSince = time.Time{} // sans statut frais, le compte repart de zéro
	case per && len(st.OffSymbols()) == 0:
		ended = true
		text = fmt.Sprintf("&#x25B6;&#xFE0F; <b>Robot en marche sur tous ses symboles</b> &#183; %s\nFin de l'attente.", name)
	case !per && st.TargetCharts > 0:
		ended = true
		text = fmt.Sprintf("&#x25B6;&#xFE0F; <b>Robot démarré hors go-to-market</b> &#183; %s\n"+
			"Démarré à la main ou depuis l'app : fin de l'attente.", name)
	case st.LastKill.At != nil && st.LastKill.At.After(w.Since):
		ended = true
		text = fmt.Sprintf("&#x1F6D1; <b>Attente interrompue</b> &#183; %s\nLa Mère a de nouveau tout arrêté. /relancer pour recommencer.", name)
	case now.Sub(w.Since) >= maxWait:
		ended = true
		text = fmt.Sprintf("&#x231B; <b>Fin de l'attente après %d h</b> &#183; %s\n"+
			"Le marché n'est jamais resté favorable %d min d'affilée. Robot toujours éteint, surveillance active.\n"+
			"/relancer : attendre de nouveau &#183; /go : démarrer maintenant",
			int(maxWait.Hours()), name, int(favorableHold.Minutes()))
	case per:
		text, markup = b.tickSymbols(w, st, now, name, account)
	default:
		favorable, reasons := verdict(st)
		switch {
		case !favorable:
			w.FavorableSince = time.Time{}
			if w.token != "" {
				delete(b.pending, w.token)
				w.token = ""
				text = fmt.Sprintf("&#x26A0;&#xFE0F; <b>Go-to-market retiré</b> &#183; %s\nLe marché n'est plus favorable :\n- %s\n"+
					"La Mère continue de surveiller.", name, html.EscapeString(strings.Join(reasons, "\n- ")))
			}
		case w.FavorableSince.IsZero():
			w.FavorableSince = now
		}
		switch {
		case text != "":
		case favorable && w.token == "" && now.Sub(w.FavorableSince) >= favorableHold && st.PausedUntil(now).IsZero() &&
			(w.ProposedAt.IsZero() || now.Sub(w.ProposedAt) >= reproposeAfter):
			w.token = newToken()
			b.pending[w.token] = pendingAction{kind: "go", chat: chat, account: account, expires: now.Add(proposalValid)}
			w.ProposedAt, w.BulletinAt = now, now
			text = fmt.Sprintf("&#x1F6A6; <b>Go-to-market</b> &#183; %s\n"+
				"Marché favorable depuis %d min : la Mère propose de démarrer le robot.\n\n%s\n\n"+
				"MerePoule rouvrira %d graphique(s) du robot ; il prendra ensuite ses positions lui-même, sous les seuils et le Bouclier.\n"+
				"<i>Valable %d min.</i>",
				name, int(now.Sub(w.FavorableSince).Minutes()), marketBlock(st), st.SavedCharts, int(proposalValid.Minutes()))
			markup = map[string]any{"inline_keyboard": [][]map[string]string{{
				{"text": "▶️ Démarrer le robot", "callback_data": "go:" + w.token},
				{"text": "Pas maintenant", "callback_data": "cancel:" + w.token},
			}}}
		case now.Sub(w.BulletinAt) >= bulletinEvery:
			w.BulletinAt = now
			text = fmt.Sprintf("&#x23F3; <b>Toujours en attente du marché</b> &#183; %s\nRobot éteint depuis %s.\n\n%s",
				name, gmt(w.Since), marketBlock(st))
		}
	}
	if ended {
		if w.token != "" {
			delete(b.pending, w.token)
		}
		for _, tok := range w.symTokens {
			delete(b.pending, tok)
		}
		delete(b.watches, account)
		if b.store != nil {
			b.store.DeleteWatch(account)
		}
	} else {
		b.saveWatch(w)
	}
	b.mu.Unlock()

	if text != "" {
		b.send(ctx, chat, text, markup)
	}
}

// askGo : go-to-market à la demande, favorable ou non ; le verdict est
// affiché et le bouton le dit.
func (b *Bot) askGo(ctx context.Context, chat int64, args []string) {
	account, ok := b.pickAccount(ctx, chat, "/go", args)
	if !ok {
		return
	}
	snap, _ := b.watcher.Snapshot(account)
	st := snap.Status
	name := html.EscapeString(label(account, st.Label))
	reset, refusal := relaunchPlan(st, b.now())
	switch {
	case refusal != "":
		b.send(ctx, chat, fmt.Sprintf("&#x26D4; <b>Démarrage impossible</b> &#183; %s\n%s", name, html.EscapeString(refusal)), nil)
		return
	case reset:
		b.send(ctx, chat, fmt.Sprintf("&#x1F6D1; <b>Robot arrêté par la Mère</b> &#183; %s\n/relancer d'abord : la Mère réarme, puis attend le marché.", name), nil)
		return
	}
	if until := st.PausedUntil(b.now()); !until.IsZero() {
		b.send(ctx, chat, pauseText(name, until), nil)
		return
	}
	if perSymbol(st) {
		off := st.OffSymbols()
		var ready []string
		for _, s := range off {
			if m, _ := marketOf(st, s); m.Go() {
				ready = append(ready, s)
			}
		}
		if len(ready) == 0 {
			b.send(ctx, chat, fmt.Sprintf("&#x1F534; <b>Rien à démarrer maintenant</b> &#183; %s\nTa règle est au &#x1F534; sur les symboles éteints (%s) : "+
				"la Mère y éteindrait aussitôt le robot. Elle te proposera chacun dès qu'il passe au &#x1F7E2;.\n\n%s", name, names(off), symbolsBlock(st)), nil)
			return
		}
		token := newToken()
		b.mu.Lock()
		b.pending[token] = pendingAction{kind: "gosym", chat: chat, account: account, expires: b.now().Add(confirmWindow), symbols: ready}
		b.mu.Unlock()
		text, markup := symbolsProposal(name, st, ready, off, token, confirmWindow)
		b.send(ctx, chat, text, markup)
		return
	}
	button := "▶️ Démarrer le robot"
	if favorable, _ := verdict(st); !favorable {
		button = "▶️ Démarrer quand même"
	}
	b.send(ctx, chat, fmt.Sprintf("&#x1F6A6; <b>Go-to-market ?</b> &#183; %s\n\n%s\n\n"+
		"MerePoule rouvrira les graphiques éteints du robot ; il prendra ensuite ses positions lui-même.\n<i>Valable 60 s.</i>",
		name, marketView(st)), confirmKeyboard(button, "go", b.hold("go", chat, account, confirmWindow)))
}

// cancelWatch : /annuler arrête l'attente, robot toujours éteint.
func (b *Bot) cancelWatch(ctx context.Context, chat int64, args []string) {
	account, ok := b.pickAccount(ctx, chat, "/annuler", args)
	if !ok {
		return
	}
	if _, ok := b.watching(account); !ok {
		b.send(ctx, chat, "<b>Aucune attente du marché en cours</b> pour ce compte.", nil)
		return
	}
	b.endWatch(account)
	b.mu.Lock()
	b.noAutoWatch[account] = true
	b.mu.Unlock()
	snap, _ := b.watcher.Snapshot(account)
	b.send(ctx, chat, fmt.Sprintf("&#x21A9;&#xFE0F; <b>Attente arrêtée</b> &#183; %s\nRobot toujours éteint, surveillance active.\n"+
		"/relancer : attendre de nouveau &#183; /go : démarrer maintenant",
		html.EscapeString(label(account, snap.Status.Label))), nil)
}

// relaunch revérifie le statut (il a pu changer pendant la minute de
// confirmation), puis réarme et ouvre l'attente en arrière-plan.
func (b *Bot) relaunch(ctx context.Context, chat, msgID, account int64) {
	snap, _ := b.watcher.Snapshot(account)
	reset, refusal := relaunchPlan(snap.Status, b.now())
	if _, ok := b.watching(account); ok && refusal == "" {
		refusal = "Déjà en attente du marché."
	}
	if refusal != "" {
		b.edit(ctx, chat, msgID, "&#x26D4; <b>Relance NON déposée</b>\n"+html.EscapeString(refusal))
		return
	}
	step := "Attente du marché demandée"
	if reset {
		step = "Réarmement demandé"
	}
	b.edit(ctx, chat, msgID, fmt.Sprintf("&#x23F3; <b>%s</b>\nCompte %d", step, account))
	go b.rearmAndWatch(context.WithoutCancel(ctx), chat, account, reset)
}

func (b *Bot) rearmAndWatch(ctx context.Context, chat, account int64, reset bool) {
	if reset {
		if _, ok := b.runStep(ctx, chat, account, requests.Reset, "Réarmement", map[string]any{"reason": "relance depuis Telegram"}); !ok {
			return
		}
	}
	b.startWatch(ctx, chat, account)
}

// goMarket : bouton « Démarrer » d'un go-to-market, proposé ou demandé.
func (b *Bot) goMarket(ctx context.Context, chat, msgID, account int64) {
	snap, _ := b.watcher.Snapshot(account)
	reset, refusal := relaunchPlan(snap.Status, b.now())
	if refusal == "" && reset {
		refusal = "La Mère a de nouveau tout arrêté : /relancer d'abord."
	}
	if until := snap.Status.PausedUntil(b.now()); refusal == "" && !until.IsZero() {
		refusal = "Pause après l'arrêt d'urgence : démarrage possible à " + gmt(until) + "."
	}
	if refusal != "" {
		b.edit(ctx, chat, msgID, "&#x26D4; <b>Démarrage NON demandé</b>\n"+html.EscapeString(refusal))
		return
	}
	b.mu.Lock()
	if w, ok := b.watches[account]; ok {
		w.starting, w.token = true, ""
	}
	b.mu.Unlock()
	b.edit(ctx, chat, msgID, fmt.Sprintf("&#x23F3; <b>Démarrage demandé</b>\nCompte %d", account))
	go b.start(context.WithoutCancel(ctx), chat, account)
}

func (b *Bot) start(ctx context.Context, chat, account int64) {
	r, ok := b.runStep(ctx, chat, account, requests.Relaunch, "Démarrage", map[string]any{"reason": "go-to-market depuis Telegram"})
	if !ok {
		b.mu.Lock()
		if w, found := b.watches[account]; found {
			w.starting = false // l'attente continue
		}
		b.mu.Unlock()
		return
	}
	b.endWatch(account)
	b.send(ctx, chat, "&#x2705; <b>Robot démarré</b>\n"+html.EscapeString(r.Detail), nil)
}

// runStep dépose une demande et attend le Watchdog. Un refus ou un silence
// est rapporté dans le chat, et ok = false : rien n'est tenté à l'aveugle.
func (b *Bot) runStep(ctx context.Context, chat, account int64, kind requests.Kind, name string, payload map[string]any) (store.Request, bool) {
	device := "telegram:" + strconv.FormatInt(chat, 10)
	req, _, err := b.tracker.Submit(account, kind, "", device, "telegram", payload)
	if err != nil {
		b.send(ctx, chat, fmt.Sprintf("&#x26D4; <b>%s NON déposé</b>\n%s", name, html.EscapeString(err.Error())), nil)
		return req, false
	}
	r, ok := b.await(req.ID)
	switch {
	case !ok:
		b.send(ctx, chat, fmt.Sprintf("&#x26A0;&#xFE0F; <b>%s : la Mère n'a pas répondu en 15 s</b>\n"+
			"Rien d'autre n'est demandé ; vérifier que l'ordinateur est allumé et que MT5 tourne.", name), nil)
		return r, false
	case r.State != requests.Executed:
		b.send(ctx, chat, fmt.Sprintf("&#x26D4; <b>%s refusé par la Mère</b>\n%s", name, html.EscapeString(r.Detail)), nil)
		return r, false
	}
	return r, true
}

// pauseText : le robot ne peut pas redémarrer tout de suite après un arrêt.
func pauseText(name string, until time.Time) string {
	return fmt.Sprintf("&#x23F8;&#xFE0F; <b>Pause après l'arrêt d'urgence</b> &#183; %s\n"+
		"Le robot ne peut pas redémarrer avant %s : après un arrêt, la Mère impose %d min de pause. "+
		"/relancer réarme dès maintenant et la Mère attendra le marché ; elle proposera le go-to-market après la pause.",
		name, gmt(until), int(contract.RelaunchPause.Minutes()))
}

// tickSymbols : go-to-market par symbole (b.mu tenu). Retire les
// propositions dont plus aucun symbole n'est éligible, puis propose les
// symboles éteints passés au 🟢, hors pause et hors délai de 30 min.
func (b *Bot) tickSymbols(w *watchState, st contract.Status, now time.Time, name string, account int64) (string, any) {
	if w.symProposed == nil {
		w.symProposed = map[string]time.Time{}
	}
	off := st.OffSymbols()
	eligible := func(s string) bool {
		m, _ := marketOf(st, s)
		return m.Go() && slices.Contains(off, s)
	}
	pending := map[string]bool{}
	var keep []string
	var withdrawn []string
	for _, tok := range w.symTokens {
		p, ok := b.pending[tok]
		if !ok || now.After(p.expires) {
			delete(b.pending, tok)
			continue
		}
		any := false
		for _, s := range p.symbols {
			if eligible(s) {
				any = true
			}
		}
		if !any {
			delete(b.pending, tok)
			withdrawn = append(withdrawn, p.symbols...)
			continue
		}
		keep = append(keep, tok)
		for _, s := range p.symbols {
			pending[s] = true
		}
	}
	w.symTokens = keep
	if len(withdrawn) > 0 {
		return fmt.Sprintf("&#x26A0;&#xFE0F; <b>Go-to-market retiré</b> &#183; %s\n%s : ta règle est repassée au &#x1F534;, ou le robot y tourne déjà. "+
			"La Mère continue de surveiller.", name, names(withdrawn)), nil
	}

	var ready []string
	if st.PausedUntil(now).IsZero() {
		for _, s := range off {
			if !eligible(s) || pending[s] {
				continue
			}
			if t, ok := w.symProposed[s]; ok && now.Sub(t) < reproposeAfter {
				continue
			}
			ready = append(ready, s)
		}
	}
	if len(ready) == 0 {
		if now.Sub(w.BulletinAt) >= bulletinEvery {
			w.BulletinAt = now
			return fmt.Sprintf("&#x23F3; <b>Toujours en attente de ta règle</b> &#183; %s\nDepuis %s.\n\n%s", name, gmt(w.Since), symbolsBlock(st)), nil
		}
		return "", nil
	}

	token := newToken()
	b.pending[token] = pendingAction{kind: "gosym", chat: w.Chat, account: account, expires: now.Add(proposalValid), symbols: ready}
	w.symTokens = append(w.symTokens, token)
	for _, s := range ready {
		w.symProposed[s] = now
	}
	w.BulletinAt = now
	return symbolsProposal(name, st, ready, off, token, proposalValid)
}

// symbolsProposal : le go-to-market des symboles au 🟢, un bouton chacun.
func symbolsProposal(name string, st contract.Status, ready, off []string, token string, valid time.Duration) (string, any) {
	var sb strings.Builder
	fmt.Fprintf(&sb, "&#x1F6A6; <b>Go-to-market</b> &#183; %s\nTa règle passe au &#x1F7E2; sur %s : la Mère propose de démarrer le robot là, seulement.\n",
		name, names(ready))
	for _, s := range ready {
		m, _ := marketOf(st, s)
		fmt.Fprintf(&sb, "\n%s\n%s", plainLine(m), ruleLine(m, false))
	}
	var still []string
	for _, s := range off {
		if !slices.Contains(ready, s) {
			still = append(still, s)
		}
	}
	if len(still) > 0 {
		fmt.Fprintf(&sb, "\n\nRestent éteints : %s.", names(still))
	}
	if valid >= time.Minute {
		fmt.Fprintf(&sb, "\n<i>Valable %d min.</i>", int(valid.Minutes()))
	} else {
		fmt.Fprintf(&sb, "\n<i>Valable %d s.</i>", int(valid.Seconds()))
	}
	var rows [][]map[string]string
	for i, s := range ready {
		rows = append(rows, []map[string]string{{"text": "▶️ Démarrer " + shortName(s), "callback_data": fmt.Sprintf("gosym:%s:%d", token, i)}})
	}
	if len(ready) > 1 {
		rows = append(rows, []map[string]string{{"text": fmt.Sprintf("▶️ Démarrer les %d", len(ready)), "callback_data": "gosym:" + token + ":all"}})
	}
	rows = append(rows, []map[string]string{{"text": "Pas maintenant", "callback_data": "cancel:" + token}})
	return sb.String(), map[string]any{"inline_keyboard": rows}
}

// goSymbolsButton : « Démarrer <symbole> » ou « Démarrer les n ».
func (b *Bot) goSymbolsButton(ctx context.Context, chat, msgID int64, token, pick string) {
	b.mu.Lock()
	p, ok := b.pending[token]
	delete(b.pending, token)
	b.mu.Unlock()
	switch {
	case !ok || p.chat != chat || p.kind != "gosym":
		b.edit(ctx, chat, msgID, "&#x26D4; <b>Demande inconnue ou déjà traitée</b>")
		return
	case b.now().After(p.expires):
		b.edit(ctx, chat, msgID, "&#x231B; <b>Proposition expirée</b>\nLa Mère la refera si ta règle reste au &#x1F7E2;.")
		return
	}
	symbols := p.symbols
	if pick != "all" {
		i, err := strconv.Atoi(pick)
		if err != nil || i < 0 || i >= len(symbols) {
			b.edit(ctx, chat, msgID, "&#x26D4; <b>Demande inconnue ou déjà traitée</b>")
			return
		}
		symbols = []string{symbols[i]}
	}
	snap, _ := b.watcher.Snapshot(p.account)
	st := snap.Status
	var refusal string
	switch {
	case st.Stale(b.now()):
		refusal = "La Mère ne répond plus : vérifier que l'ordinateur est allumé et que MT5 tourne."
	case st.State == "KILL":
		refusal = "La Mère a de nouveau tout arrêté : /relancer d'abord."
	case !st.PausedUntil(b.now()).IsZero():
		refusal = "Pause après l'arrêt d'urgence : démarrage possible à " + gmt(st.PausedUntil(b.now())) + "."
	}
	var keep, dropped []string
	off := st.OffSymbols()
	for _, s := range symbols {
		if m, _ := marketOf(st, s); m.Go() && slices.Contains(off, s) {
			keep = append(keep, s)
		} else {
			dropped = append(dropped, s)
		}
	}
	if refusal == "" && len(keep) == 0 {
		refusal = names(dropped) + " : ta règle est repassée au 🔴, ou le robot y tourne déjà."
	}
	if refusal != "" {
		b.edit(ctx, chat, msgID, "&#x26D4; <b>Démarrage NON demandé</b>\n"+html.EscapeString(refusal))
		return
	}
	b.edit(ctx, chat, msgID, fmt.Sprintf("&#x23F3; <b>Démarrage demandé</b> : %s", names(keep)))
	go func(ctx context.Context) {
		r, ok := b.runStep(ctx, chat, p.account, requests.Relaunch, "Démarrage",
			map[string]any{"reason": "go-to-market par symbole depuis Telegram", "symbols": keep})
		if !ok {
			return
		}
		text := "&#x2705; <b>Démarré : " + names(keep) + "</b>\n" + html.EscapeString(r.Detail)
		if len(dropped) > 0 {
			text += "\nPas démarré(s) : " + names(dropped) + " (ta règle est repassée au 🔴, ou déjà en marche)."
		}
		b.send(ctx, chat, text, nil)
	}(context.WithoutCancel(ctx))
}
