package telegram

import (
	"context"
	"fmt"
	"html"
	"strconv"
	"time"

	"merepoule/gateway/internal/requests"
)

// Retournement (décision 28) : une bougie M5 forte contre le robot, sur un
// symbole où il a des positions. Alerte immédiate avec « Couper ce symbole »
// (ses positions fermées, le robot éteint dessus, les autres continuent) ou
// « Laisser courir ». Le Watchdog en fait un cas du Caméléon, avec son bilan.
const reversalEvery = 15 * time.Minute

func (b *Bot) tickReversals(ctx context.Context, account int64, now time.Time) {
	snap, _ := b.watcher.Snapshot(account)
	st := snap.Status
	if st.Stale(now) || st.State == "KILL" {
		return
	}
	name := html.EscapeString(label(account, st.Label))
	for _, m := range st.Market {
		if !m.Reversal || !hasPositions(st, m.Symbol) {
			continue
		}
		key := strconv.FormatInt(account, 10) + "|" + m.Symbol
		b.mu.Lock()
		if last, ok := b.reversals[key]; ok && now.Sub(last) < reversalEvery {
			b.mu.Unlock()
			continue
		}
		b.reversals[key] = now
		b.mu.Unlock()

		short := shortName(m.Symbol)
		verb := sideVerb[m.RobotSide]
		if verb == "" {
			verb = "trade"
		}
		positions, floating := 0, 0.0
		for _, e := range st.Symbols {
			if e.Symbol == m.Symbol {
				positions, floating = e.Positions, e.Floating
			}
		}
		text := fmt.Sprintf("&#x1F7E0; <b>RETOURNEMENT</b> &#183; %s\nForte bougie M5 contre le robot sur <b>%s</b>, qui y %s : %d position(s), %s.\n%s\n"+
			"<i>Couper ferme les positions de %s et y éteint le robot ; les autres continuent. Valable %d min.</i>",
			name, html.EscapeString(short), verb, positions, money(floating), ruleLine(m, false), html.EscapeString(short), int(proposalValid.Minutes()))
		for _, chat := range b.chatsFor(account) {
			token := newToken()
			b.mu.Lock()
			b.pending[token] = pendingAction{kind: "cut", chat: chat, account: account, expires: now.Add(proposalValid), symbols: []string{m.Symbol}}
			b.mu.Unlock()
			b.send(ctx, chat, text, map[string]any{"inline_keyboard": [][]map[string]string{{
				{"text": "🛑 Couper " + short, "callback_data": "cut:" + token},
				{"text": "Laisser courir", "callback_data": "cancel:" + token},
			}}})
		}
	}
}

// cutSymbol : le bouton « Couper » d'un retournement. Un geste suffit : le
// retournement se joue en minutes, et seul ce symbole est touché.
func (b *Bot) cutSymbol(ctx context.Context, chat, msgID, account int64, symbol string) {
	snap, _ := b.watcher.Snapshot(account)
	st := snap.Status
	short := html.EscapeString(shortName(symbol))
	switch {
	case st.Stale(b.now()):
		b.edit(ctx, chat, msgID, "&#x26D4; <b>Coupe NON demandée</b>\nLa Mère ne répond plus : vérifier que l'ordinateur est allumé et que MT5 tourne.")
		return
	case st.State == "KILL":
		b.edit(ctx, chat, msgID, "&#x2139;&#xFE0F; <b>Rien à couper</b>\nTout est déjà arrêté.")
		return
	}
	b.edit(ctx, chat, msgID, "&#x23F3; <b>Coupe demandée</b> : "+short)
	go func(ctx context.Context) {
		r, ok := b.runStep(ctx, chat, account, requests.Cut, "Coupe de "+shortName(symbol),
			map[string]any{"symbol": symbol, "reason": "retournement, depuis Telegram"})
		if !ok {
			return
		}
		b.send(ctx, chat, "&#x2705; <b>"+short+" coupé</b>\n"+html.EscapeString(r.Detail), nil)
	}(context.WithoutCancel(ctx))
}
