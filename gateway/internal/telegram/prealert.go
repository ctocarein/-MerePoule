package telegram

import (
	"context"
	"fmt"
	"html"
	"log"
	"math"
	"slices"
	"strconv"
	"strings"
	"time"

	"merepoule/gateway/internal/contract"
)

// Pré-alerte (décision 24). Quand la perte en cours passe sous -PreAlert
// (300), la Mère prévient sur Telegram avec « J'ai vu » et « Tout arrêter ».
// Sans « J'ai vu » en 2 min, elle appelle : appel vocal Telegram (CallMeBot),
// puis toutes les 5 min, 6 fois au plus. L'alerte se lève quand la perte
// repasse au-dessus de -(seuil - 50), que les positions sont fermées ou que
// l'arrêt d'urgence tombe : celui-ci reste l'affaire du Watchdog.
const (
	preAlertEvery = 10 * time.Second
	callAfter     = 2 * time.Minute
	callEvery     = 5 * time.Minute
	maxCalls      = 6
	rearmMargin   = 50.0
)

// Caller passe un appel vocal et renvoie la réponse du service, à montrer.
type Caller interface {
	Call(ctx context.Context, user, text string) (string, error)
}

type preAlert struct {
	token    string
	level    float64
	decision bool // niveau 2 : perte au seuil de décision (décision 28)
	seen     bool
	calls    int
	nextCall time.Time
	told     map[int64]bool // chats déjà prévenus qu'on ne peut pas les appeler
}

// preAlertLevel : le seuil de pré-alerte reste sous la limite d'arrêt ; s'il
// l'atteint, il passe à 70 % de celle-ci.
func (b *Bot) preAlertLevel(st contract.Status) float64 {
	level := b.cfg.PreAlert
	if limit := st.Config.MaxFloatingLoss; limit > 0 && level >= limit {
		level = math.Round(0.7 * limit)
	}
	return level
}

// chatsFor : les chats autorisés à voir ce compte.
func (b *Bot) chatsFor(account int64) []int64 {
	var out []int64
	for chat, limit := range b.cfg.Chats {
		if limit == nil || slices.Contains(limit, account) {
			out = append(out, chat)
		}
	}
	slices.Sort(out)
	return out
}

func (b *Bot) preAlertLoop(ctx context.Context) {
	t := time.NewTicker(preAlertEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			b.tickPreAlerts(ctx)
		}
	}
}

func (b *Bot) tickPreAlerts(ctx context.Context) {
	now := b.now()
	for _, a := range b.watcher.Accounts() {
		if b.cfg.PreAlert > 0 {
			b.tickPreAlert(ctx, a, now)
		}
		b.tickReversals(ctx, a, now)
	}
}

// decisionLevel : le seuil où le trader décide (décision 28), quand le
// Watchdog lui laisse la décision (1.32) ; 0 sinon.
func decisionLevel(st contract.Status) float64 {
	if st.Config.ManualDecision && st.Config.MaxFloatingLoss > 0 {
		return st.Config.MaxFloatingLoss
	}
	return 0
}

func (b *Bot) tickPreAlert(ctx context.Context, account int64, now time.Time) {
	snap, _ := b.watcher.Snapshot(account)
	st := snap.Status
	level := b.preAlertLevel(st)
	live := !st.Stale(now) && st.State != "KILL" && st.Positions > 0

	decide := decisionLevel(st)
	b.mu.Lock()
	p := b.preAlerts[account]
	switch {
	case live && decide > 0 && st.Floating <= -decide && (p == nil || !p.decision):
		// Nouvelle alerte, ou passage de -300 au seuil de décision : l'appel part tout de suite.
		lvl := level
		if p != nil {
			lvl = p.level
		}
		p = &preAlert{token: newToken(), level: lvl, decision: true, nextCall: now, told: map[int64]bool{}}
		b.preAlerts[account] = p
		b.mu.Unlock()
		markup := map[string]any{"inline_keyboard": [][]map[string]string{{
			{"text": "🛑 Tout arrêter", "callback_data": "stop:" + p.token},
			{"text": "✋ Laisser courir", "callback_data": "seen:" + p.token},
		}}}
		text := decisionText(account, st)
		for _, chat := range b.chatsFor(account) {
			b.send(ctx, chat, text, markup)
		}
		return
	case p == nil && live && st.Floating <= -level:
		p = &preAlert{token: newToken(), level: level, nextCall: now.Add(callAfter), told: map[int64]bool{}}
		b.preAlerts[account] = p
		b.mu.Unlock()
		markup := map[string]any{"inline_keyboard": [][]map[string]string{{
			{"text": "✅ J'ai vu", "callback_data": "seen:" + p.token},
			{"text": "🛑 Tout arrêter", "callback_data": "stop:" + p.token},
		}}}
		text := preAlertText(account, st)
		for _, chat := range b.chatsFor(account) {
			b.send(ctx, chat, text, markup)
		}
		return
	case p == nil:
		b.mu.Unlock()
		return
	case !live || st.Floating > -(p.level-rearmMargin):
		delete(b.preAlerts, account)
		b.mu.Unlock()
		if st.Stale(now) || st.State == "KILL" {
			return // l'arrêt d'urgence et la vigie ont leurs propres messages
		}
		why := fmt.Sprintf("La perte en cours est revenue à %s.", money(st.Floating))
		if st.Positions == 0 {
			why = "Les positions sont fermées."
		}
		for _, chat := range b.chatsFor(account) {
			b.send(ctx, chat, fmt.Sprintf("&#x2705; <b>Alerte levée</b> &#183; %s\n%s", html.EscapeString(label(account, st.Label)), why), nil)
		}
		return
	}
	call := !p.seen && p.calls < maxCalls && !now.Before(p.nextCall)
	if call {
		p.calls++
		p.nextCall = now.Add(callEvery)
	}
	n := p.calls
	b.mu.Unlock()
	if call {
		b.placeCalls(ctx, account, st, p, n)
	}
}

// preAlertText : l'alerte, en langage simple.
func preAlertText(account int64, st contract.Status) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "&#x1F6A8; <b>ALERTE : perte en cours %s</b> &#183; %s\n", money(st.Floating), html.EscapeString(label(account, st.Label)))
	if limit := st.Config.MaxFloatingLoss; limit > 0 && st.Config.ManualDecision {
		fmt.Fprintf(&sb, "À -%.0f, c'est toi qui décides ; la Mère ne coupe seule qu'à -%.0f.\n", limit, st.Config.FloatingLastResort)
	} else if limit > 0 {
		fmt.Fprintf(&sb, "La Mère coupe tout à -%.0f : il reste %s avant l'arrêt d'urgence.\n", limit, amount(math.Max(0, limit+st.Floating)))
	}
	sb.WriteString(worstText(st))
	fmt.Fprintf(&sb, "\n\nSans « J'ai vu » dans %d min, la Mère appelle sur Telegram.", int(callAfter.Minutes()))
	return sb.String()
}

// decisionText : l'alerte du seuil de décision (décision 28).
func decisionText(account int64, st contract.Status) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "&#x1F6A8; <b>DÉCISION À PRENDRE : perte en cours %s</b> &#183; %s\n", money(st.Floating), html.EscapeString(label(account, st.Label)))
	fmt.Fprintf(&sb, "La Mère ne coupe plus seule à -%.0f : c'est toi qui décides.", st.Config.MaxFloatingLoss)
	if lr := st.Config.FloatingLastResort; lr > 0 {
		fmt.Fprintf(&sb, " Sans décision, elle coupera tout à -%.0f (il reste %s).", lr, amount(math.Max(0, lr+st.Floating)))
	}
	sb.WriteString("\n" + worstText(st))
	fmt.Fprintf(&sb, "\n\nLa Mère t'appelle maintenant, puis toutes les %d min, jusqu'à ta réponse.", int(callEvery.Minutes()))
	return sb.String()
}

// worstText : les positions, la plus touchée, son marché et ta règle.
func worstText(st contract.Status) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "%d position(s) ouverte(s)", st.Positions)
	var worst *contract.Exposure
	for i := range st.Symbols {
		if worst == nil || st.Symbols[i].Floating < worst.Floating {
			worst = &st.Symbols[i]
		}
	}
	if worst != nil {
		side := "achats et ventes"
		switch {
		case worst.SellVolume == 0:
			side = "achats"
		case worst.BuyVolume == 0:
			side = "ventes"
		}
		fmt.Fprintf(&sb, " ; la plus touchée : %s (%s), %s", html.EscapeString(shortName(worst.Symbol)), side, money(worst.Floating))
		for _, m := range st.Market {
			if m.Symbol == worst.Symbol {
				sb.WriteString(".\n" + plainLine(m))
				if r := ruleLine(m, false); r != "" {
					sb.WriteString("\n" + r)
				}
				break
			}
		}
	}
	return sb.String()
}

// placeCalls appelle chaque chat qui n'a pas coupé l'appel.
func (b *Bot) placeCalls(ctx context.Context, account int64, st contract.Status, p *preAlert, n int) {
	name := html.EscapeString(label(account, st.Label))
	who := st.Label
	if who == "" {
		who = strconv.FormatInt(account, 10)
	}
	speech := fmt.Sprintf("Alerte Mère Poule. Le compte %s perd %.0f. La Mère coupe tout à %.0f. "+
		"Ouvrez Telegram et appuyez sur J'ai vu.", who, math.Abs(st.Floating), st.Config.MaxFloatingLoss)
	if st.Config.ManualDecision {
		speech = fmt.Sprintf("Alerte Mère Poule. Le compte %s perd %.0f. À %.0f, c'est à vous de décider. "+
			"Ouvrez Telegram. Arrêt automatique à %.0f.", who, math.Abs(st.Floating), st.Config.MaxFloatingLoss, st.Config.FloatingLastResort)
		if p.decision {
			speech = fmt.Sprintf("Décision Mère Poule. Le compte %s perd %.0f. C'est à vous de décider : ouvrez Telegram. "+
				"Arrêt automatique à %.0f.", who, math.Abs(st.Floating), st.Config.FloatingLastResort)
		}
	}
	for _, chat := range b.chatsFor(account) {
		if b.pref(chat, "call") == "off" {
			continue
		}
		target := b.callTarget(chat)
		if target == "" || b.cfg.Caller == nil {
			b.mu.Lock()
			told := p.told[chat]
			p.told[chat] = true
			b.mu.Unlock()
			if !told {
				b.send(ctx, chat, fmt.Sprintf("&#x1F4DE; <b>Pas d'appel possible</b> &#183; %s\n"+
					"La Mère ne sait pas qui appeler : /appel pour le régler.", name), nil)
			}
			continue
		}
		reply, err := b.cfg.Caller.Call(ctx, target, speech)
		log.Printf("appel d'alerte n°%d du compte %d vers %s : %v %s", n, account, target, err, reply) // trace : le téléphone a-t-il été appelé ?
		if err != nil {
			b.send(ctx, chat, fmt.Sprintf("&#x1F4DE; <b>Appel impossible</b> &#183; %s\n%s\n<i>/appel test pour vérifier.</i>",
				name, html.EscapeString(err.Error())), nil)
			continue
		}
		next := ""
		if n < maxCalls {
			next = fmt.Sprintf(" Nouvel appel dans %d min sans « J'ai vu ».", int(callEvery.Minutes()))
		}
		b.send(ctx, chat, fmt.Sprintf("&#x1F4DE; <b>Appel n°%d</b> &#183; %s\nLa Mère appelle %s sur Telegram (perte en cours %s).%s",
			n, name, html.EscapeString(target), money(st.Floating), next), nil)
	}
}

// preAlertButton : « J'ai vu » arrête les appels ; « Tout arrêter » aussi,
// puis propose l'arrêt d'urgence (avec sa confirmation).
func (b *Bot) preAlertButton(ctx context.Context, chat, msgID int64, action, token string) {
	var account int64
	var p *preAlert
	b.mu.Lock()
	for a, x := range b.preAlerts {
		if x.token == token {
			account, p = a, x
		}
	}
	if p != nil {
		p.seen = true
	}
	b.mu.Unlock()
	if p == nil {
		b.edit(ctx, chat, msgID, "&#x2139;&#xFE0F; <b>Alerte déjà levée</b>\n/etat pour voir le compte, /kill pour tout arrêter.")
		return
	}
	snap, _ := b.watcher.Snapshot(account)
	st := snap.Status
	name := html.EscapeString(label(account, st.Label))
	switch {
	case p.decision && action == "seen":
		b.edit(ctx, chat, msgID, fmt.Sprintf("&#x270B; <b>Tu laisses courir</b> (%s) &#183; %s\nPerte en cours %s ; la Mère coupera tout seule à -%.0f. "+
			"Plus d'appel pour cette alerte.", gmt(b.now()), name, money(st.Floating), st.Config.FloatingLastResort))
	case st.Config.ManualDecision:
		b.edit(ctx, chat, msgID, fmt.Sprintf("&#x2705; <b>Vu à %s</b> &#183; %s\nPerte en cours %s ; à -%.0f, c'est toi qui décides, "+
			"arrêt automatique à -%.0f. Plus d'appel pour cette alerte.", gmt(b.now()), name, money(st.Floating), st.Config.MaxFloatingLoss, st.Config.FloatingLastResort))
	default:
		b.edit(ctx, chat, msgID, fmt.Sprintf("&#x2705; <b>Vu à %s</b> &#183; %s\nPerte en cours %s ; la Mère coupe tout à -%.0f si ça continue. "+
			"Plus d'appel pour cette alerte.", gmt(b.now()), name, money(st.Floating), st.Config.MaxFloatingLoss))
	}
	if action == "stop" {
		b.askKill(ctx, chat, []string{strconv.FormatInt(account, 10)})
	}
}

// callTarget : qui appeler pour ce chat, @nom Telegram ou numéro.
func (b *Bot) callTarget(chat int64) string {
	if t := b.pref(chat, "call_user"); t != "" {
		return t
	}
	return b.cfg.CallUser
}

// callCommand : /appel (où en est l'appel), /appel test, /appel off|on,
// /appel @nom ou /appel +225… pour changer qui est appelé.
func (b *Bot) callCommand(ctx context.Context, chat int64, args []string) {
	if len(args) > 0 {
		a := args[0]
		switch {
		case strings.EqualFold(a, "off"):
			b.setPref(chat, "call", "off")
			b.send(ctx, chat, "&#x1F4DE; <b>Appel d'alerte coupé</b>\nL'alerte arrive toujours sur Telegram, sans appel. /appel on pour le reprendre.", nil)
			return
		case strings.EqualFold(a, "on"):
			b.setPref(chat, "call", "on")
			b.send(ctx, chat, "&#x1F4DE; <b>Appel d'alerte repris</b>", nil)
			return
		case strings.EqualFold(a, "test"):
			b.testCall(ctx, chat)
			return
		case strings.HasPrefix(a, "@") || strings.HasPrefix(a, "+"):
			b.setPref(chat, "call_user", a)
			b.send(ctx, chat, fmt.Sprintf("&#x1F4DE; <b>La Mère appellera %s</b>\n/appel test pour essayer.", html.EscapeString(a)), nil)
			return
		}
	}
	var sb strings.Builder
	sb.WriteString("&#x1F4DE; <b>Appel d'alerte</b>\n")
	if b.cfg.PreAlert <= 0 {
		sb.WriteString("La pré-alerte est coupée sur cette passerelle.")
		b.send(ctx, chat, sb.String(), nil)
		return
	}
	target := b.callTarget(chat)
	shown := "<b>" + html.EscapeString(target) + "</b>"
	if target == "" {
		shown = "(personne : voir plus bas)"
	}
	fmt.Fprintf(&sb, "Quand la perte en cours atteint -%.0f, la Mère envoie une alerte. Sans « J'ai vu » en %d min, elle appelle %s "+
		"sur Telegram, puis toutes les %d min (%d appels au plus). L'arrêt d'urgence tombe ensuite comme avant.\n",
		b.cfg.PreAlert, int(callAfter.Minutes()), shown, int(callEvery.Minutes()), maxCalls)
	if b.pref(chat, "call") == "off" {
		sb.WriteString("État : <b>coupé</b> (/appel on pour le reprendre).\n")
	} else {
		sb.WriteString("État : <b>actif</b>.\n")
	}
	if target == "" {
		sb.WriteString("\nLa Mère ne connaît pas ton nom Telegram : en choisir un (Paramètres › Nom d'utilisateur), puis écrire ici, " +
			"ou taper /appel +225… avec ton numéro.\n")
	}
	sb.WriteString("\nPremière fois : envoyer /start à @CallMeBot_txtbot pour l'autoriser à appeler (service gratuit CallMeBot).\n" +
		"<i>/appel test : essayer maintenant &#183; /appel off : couper &#183; /appel @nom : changer qui est appelé</i>")
	b.send(ctx, chat, sb.String(), nil)
}

func (b *Bot) testCall(ctx context.Context, chat int64) {
	target := b.callTarget(chat)
	switch {
	case b.cfg.Caller == nil:
		b.send(ctx, chat, "&#x1F4DE; <b>Appel indisponible</b> sur cette passerelle.", nil)
		return
	case target == "":
		b.send(ctx, chat, "&#x1F4DE; <b>Personne à appeler</b>\nLa Mère ne connaît pas ton nom Telegram : /appel pour le régler.", nil)
		return
	}
	reply, err := b.cfg.Caller.Call(ctx, target, "Test Mère Poule. Si vous entendez ce message, l'appel d'alerte fonctionne.")
	if err != nil {
		b.send(ctx, chat, fmt.Sprintf("&#x1F4DE; <b>Appel de test impossible</b> vers %s\n%s\n\n"+
			"Première fois : envoyer /start à @CallMeBot_txtbot, puis refaire /appel test.",
			html.EscapeString(target), html.EscapeString(err.Error())), nil)
		return
	}
	text := fmt.Sprintf("&#x1F4DE; <b>Appel de test lancé</b> vers %s\nLe téléphone doit sonner dans la minute ; une voix lit le message.",
		html.EscapeString(target))
	if reply != "" {
		text += "\n<i>Réponse du service : " + html.EscapeString(reply) + "</i>"
	}
	b.send(ctx, chat, text, nil)
}
