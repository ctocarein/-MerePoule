package telegram

import (
	"context"
	"fmt"
	"html"
	"log"
	"strconv"
	"strings"
	"time"

	"merepoule/gateway/internal/contract"
)

// Le retrait du dimanche (décision 31) : le trader fixe un capital de
// travail par compte ; chaque dimanche, la Mère dit combien dépasse ce
// capital et peut être retiré. Le compte revient ainsi toujours au même
// capital : les seuils de risque, en montants fixes, restent justes. La
// Mère ne retire rien : MT5 ne sait pas le faire, le retrait se fait dans
// l'espace client du courtier.
const (
	retraitDay    = time.Sunday
	retraitAt     = 18 * time.Hour // 18:00 GMT
	retraitMin    = 10.0           // en dessous, les frais de réseau mangent trop
	retraitWindow = 7 * 24 * time.Hour
)

// nextRetrait : prochain dimanche 18:00 GMT.
func nextRetrait(now time.Time) time.Time {
	day := now.UTC().Truncate(24 * time.Hour)
	t := day.AddDate(0, 0, (int(retraitDay)-int(day.Weekday())+7)%7).Add(retraitAt)
	if !now.Before(t) {
		t = t.AddDate(0, 0, 7)
	}
	return t
}

func capitalKey(account int64) string { return "capital:" + strconv.FormatInt(account, 10) }

// capital : le capital de travail d'un compte pour ce chat ; 0 = pas fixé.
func (b *Bot) capital(chat, account int64) float64 {
	v, err := strconv.ParseFloat(b.pref(chat, capitalKey(account)), 64)
	if err != nil || v <= 0 {
		return 0
	}
	return v
}

func (b *Bot) retraitOn(chat int64) bool { return b.pref(chat, "retrait") != "off" }

// surplus : ce qui peut sortir sans descendre sous le capital. Avec des
// positions ouvertes, une perte en cours compte déjà : on part du plus petit
// du solde et des fonds propres.
func surplus(st contract.Status, capital float64) float64 {
	base := st.Balance
	if st.Positions > 0 && st.Equity < base {
		base = st.Equity
	}
	return base - capital
}

// marginAfter : niveau de marge après un retrait, positions ouvertes ;
// 0 si inconnu.
func marginAfter(st contract.Status, out float64) float64 {
	if st.Positions == 0 || st.MarginLevel <= 0 || st.Equity <= 0 {
		return 0
	}
	used := st.Equity / (st.MarginLevel / 100)
	return (st.Equity - out) / used * 100
}

// retraitText : le point retrait d'un compte ; ok = false sans statut frais.
func (b *Bot) retraitText(chat, account int64, now time.Time) (string, bool) {
	snap, found := b.watcher.Snapshot(account)
	st := snap.Status
	if !found || st.Stale(now) {
		return "", false
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "&#x1F4B0; <b>Retrait de la semaine</b> &#183; %s\n", html.EscapeString(label(account, st.Label)))
	fmt.Fprintf(&sb, "Solde %s", amount(st.Balance))
	if st.Positions > 0 {
		fmt.Fprintf(&sb, " &#183; fonds propres %s", amount(st.Equity))
	}
	if b.store != nil {
		if smp, ok, err := b.store.FirstSample(account, now.Add(-retraitWindow)); err == nil && ok {
			fmt.Fprintf(&sb, " &#183; sur 7 jours %s", money(st.Equity-smp.Equity))
		}
	}
	sb.WriteString("\n")

	c := b.capital(chat, account)
	if c == 0 {
		fmt.Fprintf(&sb, "\n&#x2139;&#xFE0F; <b>Capital de travail pas encore fixé.</b>\n"+
			"Choisis le montant qui reste toujours sur le compte, par exemple :\n<code>/retrait capital %.0f %d</code>\n"+
			"<i>Chaque dimanche, la Mère te dira ce qui le dépasse.</i>", st.Balance, account)
		return sb.String(), true
	}
	fmt.Fprintf(&sb, "Capital de travail %s\n\n", amount(c))
	s := surplus(st, c)
	switch {
	case s < 0:
		fmt.Fprintf(&sb, "&#x1F534; <b>Rien à retirer</b> : le compte est %s sous son capital de travail.\n"+
			"<i>Relis le journal de la semaine avant de laisser le robot continuer.</i>", amount(-s))
		return sb.String(), true
	case s < retraitMin:
		fmt.Fprintf(&sb, "&#x26AA; <b>Excédent %s</b> : trop petit pour un retrait (frais de réseau). On attend la semaine prochaine.", amount(s))
		return sb.String(), true
	}
	fmt.Fprintf(&sb, "&#x1F7E2; <b>À retirer : %s</b>\n", amount(s))
	if st.Positions > 0 {
		fmt.Fprintf(&sb, "&#x26A0;&#xFE0F; %d position(s) ouverte(s) : attendre qu'elles soient fermées.", st.Positions)
		if lvl := marginAfter(st, s); lvl > 0 {
			fmt.Fprintf(&sb, " Retirer maintenant ferait passer la marge de %.0f %% à %.0f %%.", st.MarginLevel, lvl)
		}
		sb.WriteString("\n")
	}
	sb.WriteString("\n<i>Espace client du courtier, retrait en USDT vers ton adresse de dépôt Binance ; " +
		"même réseau des deux côtés (TRC20 avec TRC20). Le compte revient à son capital : tes seuils restent justes.</i>")
	return sb.String(), true
}

// publishRetrait : le point retrait de chaque compte, à chaque chat qui ne
// l'a pas coupé.
func (b *Bot) publishRetrait(ctx context.Context) {
	now := b.now()
	for chat := range b.cfg.Chats {
		if !b.retraitOn(chat) {
			continue
		}
		for _, a := range b.accounts(chat) {
			if text, ok := b.retraitText(chat, a, now); ok {
				b.send(ctx, chat, text, nil)
			}
		}
	}
}

func (b *Bot) retraitLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Until(nextRetrait(time.Now()))):
			b.publishRetrait(ctx)
		}
	}
}

// retraitCommand : /retrait (tout de suite), /retrait capital 1000 [compte],
// /retrait off, /retrait on.
func (b *Bot) retraitCommand(ctx context.Context, chat int64, args []string) {
	now := b.now()
	if len(args) > 0 {
		switch strings.ToLower(args[0]) {
		case "off", "stop", "non":
			b.setPref(chat, "retrait", "off")
			b.send(ctx, chat, "&#x1F4B0; <b>Point retrait du dimanche coupé</b>\n/retrait on pour le reprendre, /retrait pour le lire à la demande.", nil)
			return
		case "on", "oui":
			b.setPref(chat, "retrait", "on")
			b.send(ctx, chat, "&#x1F4B0; <b>Point retrait du dimanche repris</b>\nProchain le "+nextRetrait(now).Format("02/01")+" à "+gmt(nextRetrait(now))+".", nil)
			return
		case "capital":
			b.setCapital(ctx, chat, args[1:])
			return
		}
	}
	sent := false
	for _, a := range b.accounts(chat) {
		if text, ok := b.retraitText(chat, a, now); ok {
			b.send(ctx, chat, text, nil)
			sent = true
		}
	}
	if !sent {
		b.send(ctx, chat, "&#x1F4B0; <b>Pas de point retrait pour l'instant</b>\nLa Mère n'a pas de nouvelles fraîches du compte.", nil)
	}
}

// setCapital : /retrait capital 1000 [compte].
func (b *Bot) setCapital(ctx context.Context, chat int64, args []string) {
	if len(args) == 0 {
		b.send(ctx, chat, "&#x2139;&#xFE0F; Exemple : <code>/retrait capital 1000</code>, avec le numéro du compte s'il y en a plusieurs.", nil)
		return
	}
	v, err := strconv.ParseFloat(strings.Replace(args[0], ",", ".", 1), 64)
	if err != nil || v <= 0 {
		b.send(ctx, chat, "&#x26D4; <b>Montant invalide</b> : "+html.EscapeString(args[0]), nil)
		return
	}
	account, ok := b.pickAccount(ctx, chat, "/retrait capital "+args[0], args[1:])
	if !ok {
		return
	}
	b.setPref(chat, capitalKey(account), strconv.FormatFloat(v, 'f', 2, 64))
	log.Printf("telegram: capital de travail du compte %d fixé à %.2f par le chat %d", account, v, chat)
	b.send(ctx, chat, fmt.Sprintf("&#x1F4B0; <b>Capital de travail : %s</b> sur %d\nChaque dimanche à %s, la Mère dira ce qui le dépasse. /retrait pour voir maintenant.",
		amount(v), account, gmt(nextRetrait(b.now()))), nil)
}
