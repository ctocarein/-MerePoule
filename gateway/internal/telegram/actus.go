package telegram

import (
	"context"
	"encoding/json"
	"fmt"
	"html"
	"log"
	"slices"
	"strings"
	"time"

	"merepoule/gateway/internal/contract"
)

// L'Actus du marché (décision 22) : toutes les 30 min, la Mère publie la
// météo du marché des symboles du robot, en mots simples, pour qui ne lit
// pas les graphiques. C'est une information : elle ne décide rien.
const actusEvery = 30 * time.Minute

type weather int

const (
	calm  weather = iota // pas de grand mouvement
	good                 // le marché va dans le sens du robot
	windy                // mouvement marqué, sens du robot inconnu ou mixte
	rain                 // le marché va contre le robot
	storm                // marché nerveux, grands écarts
)

var weatherIcon = map[weather]string{
	calm:  "&#x1F324;&#xFE0F;",
	good:  "&#x2600;&#xFE0F;",
	windy: "&#x1F32C;&#xFE0F;",
	rain:  "&#x1F327;&#xFE0F;",
	storm: "&#x26C8;&#xFE0F;",
}

const weatherLegend = "&#x2600;&#xFE0F; bon pour le robot &#183; &#x1F324;&#xFE0F; tranquille &#183; &#x1F32C;&#xFE0F; ça bouge &#183; " +
	"&#x1F327;&#xFE0F; contre le robot &#183; &#x26C8;&#xFE0F; nerveux"

// weatherOf ne dit « contre le robot » ou « bon pour le robot » que si son
// sens est connu (Watchdog 1.27) ; sinon, un mouvement marqué est « ça bouge ».
// nowTrend : la tendance sur laquelle le trader décide. Sur 1 h si le
// Watchdog la donne (1.33), sinon sur 4 h comme avant.
func nowTrend(m contract.Market) (trend string, chg float64, span string) {
	if m.Trend1h != "" {
		return m.Trend1h, m.Chg60m, "1 h"
	}
	return m.Trend, m.Chg4h, "4 h"
}

func weatherOf(m contract.Market) weather {
	_, known := sideVerb[m.RobotSide]
	trend, _, _ := nowTrend(m)
	switch {
	case m.Volatility == "agite":
		return storm
	case trend != "hausse" && trend != "baisse":
		return calm
	case !known:
		return windy
	case against(m):
		return rain
	}
	return good
}

// nextActus : prochaine heure pile ou demi-heure.
func nextActus(now time.Time) time.Time { return now.Truncate(actusEvery).Add(actusEvery) }

// pct : "+0,6 %", à la française.
func pct(v float64) string { return strings.Replace(fmt.Sprintf("%+.1f", v), ".", ",", 1) + " %" }

func money(v float64) string { return strings.Replace(fmt.Sprintf("%+.2f", v), ".", ",", 1) }

func shortName(symbol string) string { return strings.TrimPrefix(symbol, "MAX ") }

func moveText(m contract.Market) string {
	trend, chg, span := nowTrend(m)
	small := 0.3 // % en 4 h ; sur 1 h, un tiers
	if span == "1 h" {
		small = 0.1
	}
	switch {
	case trend == "hausse":
		return "monte nettement"
	case trend == "baisse":
		return "baisse nettement"
	case chg >= small:
		return "monte un peu"
	case chg <= -small:
		return "baisse un peu"
	}
	return "reste stable"
}

var moodPlain = map[string]string{
	"calme":  "Marché très calme.",
	"normal": "Mouvements habituels.",
	"agite":  "Marché très nerveux, avec de grands écarts.",
}

var sideVerb = map[string]string{"buy": "achète", "sell": "vend"}

// robotShort : ce que le marché fait au robot, sans majuscule ; "" si son
// sens est inconnu.
func robotShort(m contract.Market) string {
	verb, known := sideVerb[m.RobotSide]
	switch {
	case m.RobotSide == "both":
		return "le robot y achète et y vend"
	case !known:
		return ""
	case against(m):
		return "contre le robot, qui y " + verb
	case nowTrendStrong(m):
		return "bon pour le robot, qui y " + verb
	}
	return "le robot y " + verb + " : rien à signaler"
}

func robotText(m contract.Market) string {
	s := robotShort(m)
	if s == "" {
		return ""
	}
	return strings.ToUpper(s[:1]) + s[1:] + "."
}

var moodShort = map[string]string{"calme": "marché très calme", "normal": "mouvements habituels", "agite": "marché très nerveux"}

// plainLine : un symbole en une ligne simple, pour /etat et les messages
// d'attente du marché.
func plainLine(m contract.Market) string {
	_, chg, span := nowTrend(m)
	line := fmt.Sprintf("%s <b>%s</b> %s (%s en %s)", weatherIcon[weatherOf(m)], html.EscapeString(shortName(m.Symbol)), moveText(m), pct(chg), span)
	if mood := moodShort[m.Volatility]; mood != "" {
		line += ", " + mood
	}
	if r := robotShort(m); r != "" {
		line += " &#183; " + r
	}
	return line
}

// amount : "10480,00", à la française.
func amount(v float64) string { return strings.Replace(fmt.Sprintf("%.2f", v), ".", ",", 1) }

// headline : le résumé « En bref », d'après le symbole le plus inquiétant.
func headline(ms []contract.Market) string {
	worst := calm
	var names []string
	for _, m := range ms {
		w := weatherOf(m)
		switch {
		case w > worst:
			worst, names = w, []string{shortName(m.Symbol)}
		case w == worst:
			names = append(names, shortName(m.Symbol))
		}
	}
	list := html.EscapeString(strings.Join(names, ", "))
	switch worst {
	case storm:
		return weatherIcon[storm] + " <b>Marché nerveux</b>\nGrands mouvements sur " + list + " : prudence."
	case rain:
		return weatherIcon[rain] + " <b>Vent contraire</b>\n" + list + " : le prix part dans le sens qui fait perdre le robot."
	case windy:
		return weatherIcon[windy] + " <b>Ça bouge</b>\nMouvement marqué sur " + list + ", sans nervosité."
	case good:
		return weatherIcon[good] + " <b>Beau temps pour le robot</b>\nLe marché va dans son sens, sans nervosité."
	}
	return weatherIcon[calm] + " <b>Marché tranquille</b>\nPas de grand mouvement, rien de nerveux."
}

// robotStatus : l'état du robot en une phrase.
func (b *Bot) robotStatus(account int64, st contract.Status) string {
	switch {
	case st.State == "KILL":
		why := ""
		if st.LastKill.Reason != nil {
			why = " (" + html.EscapeString(*st.LastKill.Reason) + ")"
		}
		text := "&#x1F6D1; <b>Robot arrêté</b> par la Mère" + why + ". /relancer pour repartir"
		if until := st.PausedUntil(b.now()); !until.IsZero() {
			text += " (robot pas avant " + gmt(until) + ")"
		}
		return text + "."
	case st.State == "PAUSE":
		return "&#x23F8;&#xFE0F; <b>Robot en pause</b> : ses positions sont gardées."
	case st.TargetCharts > 0 && st.Positions == 0:
		return "&#x1F916; <b>Robot en marche</b>, sans position pour l'instant."
	case st.TargetCharts > 0:
		limit := fmt.Sprintf("la Mère coupe à -%.0f", st.Config.MaxFloatingLoss)
		if st.Config.ManualDecision {
			limit = fmt.Sprintf("tu décides à -%.0f, arrêt automatique à -%.0f", st.Config.MaxFloatingLoss, st.Config.FloatingLastResort)
		}
		return fmt.Sprintf("&#x1F916; <b>Robot en marche</b> : %d position(s), résultat en cours %s (%s).",
			st.Positions, money(st.Floating), limit)
	}
	if w, ok := b.watching(account); ok {
		return "&#x1F634; <b>Robot éteint</b> : la Mère attend un bon moment pour proposer de le relancer (depuis " + gmt(w.Since) + ")."
	}
	return "&#x1F634; <b>Robot éteint</b>."
}

// actusText met en forme l'actus d'un compte ; ok = false sans statut frais
// ou sans marché lu.
func (b *Bot) actusText(account int64, now time.Time) (string, bool) {
	snap, found := b.watcher.Snapshot(account)
	st := snap.Status
	if !found || st.Stale(now) || len(st.Market) == 0 {
		return "", false
	}
	ms := slices.Clone(st.Market)
	slices.SortStableFunc(ms, func(x, y contract.Market) int { return int(weatherOf(y)) - int(weatherOf(x)) }) // le plus inquiétant d'abord

	var sb strings.Builder
	fmt.Fprintf(&sb, "&#x1F425; <b>L'Actus du marché</b> &#183; %s\n<i>%s</i>\n\n", html.EscapeString(label(account, st.Label)), gmt(now))
	sb.WriteString("<blockquote>" + headline(ms) + "</blockquote>\n")
	if r := ruleSummary(ms); r != "" {
		sb.WriteString(r + "\n")
	}
	if r := ruleMissing(st); r != "" {
		sb.WriteString(r + "\n")
	}
	for _, m := range ms {
		_, chg, span := nowTrend(m)
		fmt.Fprintf(&sb, "\n%s <b>%s</b> %s (%s en %s, %s sur 24 h). %s",
			weatherIcon[weatherOf(m)], html.EscapeString(shortName(m.Symbol)), moveText(m), pct(chg), span, pct(m.Chg24h), moodPlain[m.Volatility])
		if r := robotText(m); r != "" {
			sb.WriteString("\n<i>" + r + "</i>")
		}
		if r := ruleLine(m, hasPositions(st, m.Symbol)); r != "" {
			sb.WriteString("\n" + r)
		}
		sb.WriteString("\n")
	}
	sb.WriteString("\n" + b.robotStatus(account, st))
	if d := b.daySummary(account, st, now); d != "" {
		sb.WriteString("\n" + d)
	}
	if c := b.chameleonSummary(account, st, now); c != "" {
		sb.WriteString("\n" + c)
	}
	fmt.Fprintf(&sb, "\n\n<i>%s\nProchaine actus à %s &#183; /actus off pour la couper</i>", weatherLegend, gmt(nextActus(now)))
	return sb.String(), true
}

func (b *Bot) actusOn(chat int64) bool { return b.pref(chat, "actus") != "off" }

func (b *Bot) setActus(chat int64, on bool) {
	if on {
		b.setPref(chat, "actus", "on")
	} else {
		b.setPref(chat, "actus", "off")
	}
}

// pref : préférence d'un chat, "" si jamais posée.
func (b *Bot) pref(chat int64, key string) string {
	if b.store == nil {
		b.mu.Lock()
		defer b.mu.Unlock()
		return b.prefs[chat][key]
	}
	v, err := b.store.ChatPref(chat, key)
	if err != nil {
		log.Printf("telegram: préférence %s du chat %d illisible : %v", key, chat, err)
	}
	return v
}

func (b *Bot) setPref(chat int64, key, value string) {
	if b.store == nil {
		b.mu.Lock()
		defer b.mu.Unlock()
		if b.prefs[chat] == nil {
			b.prefs[chat] = map[string]string{}
		}
		b.prefs[chat][key] = value
		return
	}
	if err := b.store.SetChatPref(chat, key, value); err != nil {
		log.Printf("telegram: préférence %s du chat %d non enregistrée : %v", key, chat, err)
	}
}

// publishActus : l'actus de chaque compte, à chaque chat qui ne l'a pas coupée.
func (b *Bot) publishActus(ctx context.Context) {
	now := b.now()
	for chat := range b.cfg.Chats {
		if !b.actusOn(chat) {
			continue
		}
		for _, a := range b.accounts(chat) {
			if text, ok := b.actusText(a, now); ok {
				b.send(ctx, chat, text, nil)
			}
		}
	}
}

func (b *Bot) actusLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Until(nextActus(time.Now()))):
			b.publishActus(ctx)
		}
	}
}

// actusCommand : /actus (tout de suite), /actus off, /actus on.
func (b *Bot) actusCommand(ctx context.Context, chat int64, args []string) {
	now := b.now()
	if len(args) > 0 {
		switch strings.ToLower(args[0]) {
		case "off", "stop", "non":
			b.setActus(chat, false)
			b.send(ctx, chat, "&#x1F4F0; <b>Actus du marché coupée</b>\n/actus on pour la reprendre, /actus pour la lire à la demande.", nil)
			return
		case "on", "oui":
			b.setActus(chat, true)
			b.send(ctx, chat, fmt.Sprintf("&#x1F4F0; <b>Actus du marché reprise</b>\nToutes les 30 min, prochaine à %s.", gmt(nextActus(now))), nil)
			return
		}
	}
	sent := false
	for _, a := range b.accounts(chat) {
		if text, ok := b.actusText(a, now); ok {
			b.send(ctx, chat, text, nil)
			sent = true
		}
	}
	if !sent {
		b.send(ctx, chat, "&#x1F4F0; <b>Pas d'actus pour l'instant</b>\nLa Mère n'a pas de marché frais à raconter : Watchdog muet, ou antérieur à la version 1.25.", nil)
	}
}

var tfArrow = map[string]string{"hausse": "&#x2197;&#xFE0F;", "baisse": "&#x2198;&#xFE0F;", "neutre": "&#x27A1;&#xFE0F;"}

// trendWord : flèche et mot, « ↘️ baisse ».
func trendWord(trend string) string {
	if trend == "" {
		return "?"
	}
	return arrow(trend) + " " + trend
}

// ruleMissing : le Watchdog ne donne pas encore les tendances M5, M30, H1
// (version antérieure à 1.30) ; "" si elles sont là ou sans marché.
func ruleMissing(st contract.Status) string {
	if len(st.Market) == 0 {
		return ""
	}
	for _, m := range st.Market {
		if m.Rule != "" {
			return ""
		}
	}
	return "<i>&#x2139;&#xFE0F; Tendances M5, M30, H1 et ta règle : remettre MerePoule sur son graphique dans MT5 (version 1.31 ou plus) pour les voir ici.</i>"
}

func arrow(trend string) string {
	if a, ok := tfArrow[trend]; ok {
		return a
	}
	return "?"
}

func hasPositions(st contract.Status, symbol string) bool {
	for _, e := range st.Symbols {
		if e.Symbol == symbol && e.Positions > 0 {
			return true
		}
	}
	return false
}

// ruleLine : le verdict de la règle choisie pour ce symbole (décision 30 ;
// tendance avant le Watchdog 1.34), avec la raison en clair ; "" sans
// règle (Watchdog antérieur à 1.30).
func ruleLine(m contract.Market, positions bool) string {
	if m.Rule == "" {
		return ""
	}
	var line string
	switch m.RuleMode {
	case "jump":
		line = verdictIcon(m) + " &#183; règle saut &#183; " + jumpText(m.JumpAgeMin) + "\n<i>" + jumpWhy(m) +
			" Tendances, pour info : M5 " + trendWord(m.M5) + " &#183; M30 " + trendWord(m.M30) + " &#183; H1 " + trendWord(m.H1) + ".</i>"
	case "both":
		trend := trendRuleLine(m)
		_, why, _ := strings.Cut(trend, "\n")
		line = fmt.Sprintf("%s &#183; règle tendance et saut &#183; M5 %s &#183; M30 %s &#183; H1 %s &#183; %s\n%s\n<i>%s</i>",
			verdictIcon(m), trendWord(m.M5), trendWord(m.M30), trendWord(m.H1), jumpText(m.JumpAgeMin), why, jumpWhy(m))
	case "none":
		line = fmt.Sprintf("&#x26AA; <b>Sans règle</b> (ton choix) &#183; M5 %s &#183; M30 %s &#183; H1 %s\n<i>Le robot y tourne sans filtre ; "+
			"seules les protections sur les pertes jouent.</i>", trendWord(m.M5), trendWord(m.M30), trendWord(m.H1))
	default:
		line = trendRuleLine(m)
	}
	if m.Reversal && positions {
		line += "\n&#x1F7E0; <b>Retournement</b> : forte bougie M5 contre le robot, positions ouvertes."
	}
	return line
}

// verdictIcon : « 🟢 AUTORISÉ » ou « 🔴 INTERDIT », selon la règle choisie.
func verdictIcon(m contract.Market) string {
	if m.Go() {
		return "&#x1F7E2; <b>AUTORISÉ</b>"
	}
	return "&#x1F534; <b>INTERDIT</b>"
}

// jumpText : « dernier saut il y a 12 min », comme le Watchdog.
func jumpText(age int) string {
	switch {
	case age < 0:
		return "sauts inconnus"
	case age >= jumpLookback:
		return fmt.Sprintf("aucun saut depuis plus de %d h", jumpLookback/60)
	case age == 0:
		return "saut il y a moins d'une minute"
	}
	return fmt.Sprintf("dernier saut il y a %d min", age)
}

// jumpLookback : le Watchdog cherche le dernier saut sur 12 h (Jumps.mqh).
const jumpLookback = 720

// jumpWhy : la règle saut en clair.
func jumpWhy(m contract.Market) string {
	if m.JumpLate {
		return "Pas de saut depuis trop longtemps : pause jusqu'au prochain."
	}
	return "Un saut est venu récemment : le robot peut tourner."
}

// trendRuleLine : le verdict de la règle tendance (décision 25). Il se
// confirme sur 2 bougies M5 : il peut avoir un temps de retard sur les
// tendances affichées, et la raison le dit.
func trendRuleLine(m contract.Market) string {
	want := "hausse"
	if m.Want == "sell" {
		want = "baisse"
	}
	var conf []string
	if m.M30 == want {
		conf = append(conf, "M30")
	}
	if m.H1 == want {
		conf = append(conf, "H1")
	}
	aligned := m.M5 == want && len(conf) > 0
	together := "M5"
	switch len(conf) {
	case 1:
		together = "M5 et " + conf[0]
	case 2:
		together = "M5, M30 et H1"
	}
	need := "Pour le &#x1F7E2; : M5 en " + want + ", avec M30 ou H1 en " + want + "."
	var why string
	switch {
	case m.Rule == "autorise" && aligned:
		why = together + " vont dans le sens du robot."
	case m.Rule == "autorise":
		why = "Encore autorisé : un changement doit tenir 10 min (2 bougies M5)."
	case aligned:
		why = "Presque : " + together + " vont dans son sens, autorisé si ça tient 10 min (2 bougies M5)."
	case m.M5 == "neutre":
		why = "M5 est plat. " + need
	case m.Counter:
		why = "Contre-tendance confirmée : M5, et M30 ou H1, vont contre le robot. " + need
	case m.M5 != want:
		why = "M5 va contre le robot. " + need
	default:
		why = "M5 va dans son sens, mais ni M30 ni H1 ne confirment. " + need
	}
	icon, verdict := "&#x1F534;", "INTERDIT"
	if m.Rule == "autorise" {
		icon, verdict = "&#x1F7E2;", "AUTORISÉ"
	}
	return fmt.Sprintf("%s <b>%s</b> &#183; M5 %s &#183; M30 %s &#183; H1 %s\n<i>%s</i>",
		icon, verdict, trendWord(m.M5), trendWord(m.M30), trendWord(m.H1), why)
}

// ruleSummary : où la règle choisie autorise le robot, en une ligne.
func ruleSummary(ms []contract.Market) string {
	var yes, no []string
	for _, m := range ms {
		switch {
		case m.Rule == "":
		case m.Go():
			yes = append(yes, html.EscapeString(shortName(m.Symbol)))
		default:
			no = append(no, html.EscapeString(shortName(m.Symbol)))
		}
	}
	if len(yes)+len(no) == 0 {
		return ""
	}
	switch {
	case len(yes) == 0:
		return "&#x1F3AF; Ta règle : <b>INTERDIT partout</b> pour l'instant."
	case len(no) == 0:
		return "&#x1F3AF; Ta règle : <b>AUTORISÉ partout</b>."
	}
	return "&#x1F3AF; Ta règle : <b>AUTORISÉ</b> sur " + strings.Join(yes, ", ") + " ; INTERDIT sur " + strings.Join(no, ", ") + "."
}

// dayEvents : arrêts (dont demandés à la main), relances et bilans du
// Caméléon depuis minuit GMT.
func (b *Bot) dayEvents(account int64, now time.Time) (kills, manual, relaunches, cases int, outcomes []contract.Event) {
	if b.store == nil {
		return
	}
	raws, err := b.store.EventsSince(account, now.UTC().Truncate(24*time.Hour), "kill", "relaunch", "chameleon", "chameleon_outcome")
	if err != nil {
		log.Printf("telegram: événements du jour illisibles : %v", err)
		return
	}
	for _, raw := range raws {
		var e contract.Event
		if json.Unmarshal(raw, &e) != nil {
			continue
		}
		switch e.Type {
		case "kill":
			kills++
			if e.Rule == "manual" {
				manual++
			}
		case "relaunch":
			relaunches++
		case "chameleon":
			cases++
		case "chameleon_outcome":
			outcomes = append(outcomes, e)
		}
	}
	return
}

// daySummary : le bilan du jour depuis minuit GMT ; "" sans base.
func (b *Bot) daySummary(account int64, st contract.Status, now time.Time) string {
	if b.store == nil {
		return ""
	}
	kills, manual, relaunches, _, _ := b.dayEvents(account, now)
	text := fmt.Sprintf("&#x1F4C5; <b>Aujourd'hui</b> : %d arrêt(s) d'urgence", kills)
	if manual > 0 {
		text += fmt.Sprintf(" (dont %d demandé(s) à la main)", manual)
	}
	text += fmt.Sprintf(", %d relance(s)", relaunches)
	midnight := now.UTC().Truncate(24 * time.Hour)
	if smp, ok, err := b.store.FirstSample(account, midnight); err == nil && ok {
		if smp.TS.Sub(midnight) <= 10*time.Minute {
			text += " &#183; résultat du jour " + money(st.Equity-smp.Equity)
		} else {
			text += " &#183; résultat depuis " + gmt(smp.TS) + " " + money(st.Equity-smp.Equity)
		}
		if st.Floating != 0 {
			text += ", dont " + money(st.Floating) + " en cours"
		}
	}
	return text + "."
}

// chameleonSummary : les cas du jour et le bilan cumulé du Caméléon.
func (b *Bot) chameleonSummary(account int64, st contract.Status, now time.Time) string {
	c := st.Chameleon
	if c.Mode == "" {
		return ""
	}
	var sb strings.Builder
	sb.WriteString("&#x1F98E; <b>Caméléon</b> (essai, ne ferme rien)")
	_, _, _, cases, outcomes := b.dayEvents(account, now)
	if b.store != nil {
		fmt.Fprintf(&sb, " : aujourd'hui %d cas", cases)
		if len(outcomes) > 0 {
			saved := 0.0
			for _, e := range outcomes {
				saved += e.Saved
			}
			fmt.Fprintf(&sb, ", %d bilan(s) : couper aurait %s", len(outcomes), savedText(saved))
		}
	}
	if n := len(c.Open); n > 0 {
		fmt.Fprintf(&sb, " ; %d groupe(s) suivi(s) en ce moment", n)
	}
	if c.Episodes > 0 {
		sb.WriteString(".\nDepuis le début")
		if t, h := c.ByReason["trend"], c.ByReason["heavy"]; c.ByReason != nil {
			fmt.Fprintf(&sb, " : contre-tendance %d cas%s ; perte lourde %d cas%s", t.Episodes, tally(t), h.Episodes, tally(h))
		} else {
			fmt.Fprintf(&sb, " : %d cas, couper aurait %s", c.Episodes, savedText(c.SavedTotal))
		}
	}
	return sb.String() + "."
}

func savedText(v float64) string {
	if v >= 0 {
		return "épargné " + amount(v)
	}
	return "coûté " + amount(-v)
}

func tally(t contract.ChameleonTally) string {
	if t.Episodes == 0 {
		return ""
	}
	return ", couper aurait " + savedText(t.SavedTotal)
}

func nowTrendStrong(m contract.Market) bool {
	trend, _, _ := nowTrend(m)
	return trend == "hausse" || trend == "baisse"
}
