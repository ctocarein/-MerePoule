package telegram

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"merepoule/gateway/internal/contract"
	"merepoule/gateway/internal/readiness"
	"merepoule/gateway/internal/requests"
	"merepoule/gateway/internal/store"
	"merepoule/gateway/internal/watcher"
)

const (
	me      = int64(7805445021)
	account = int64(123456)
)

// fakeTelegram imite l'API Bot : getUpdates rend la file d'attente, les
// autres méthodes sont enregistrées.
type fakeTelegram struct {
	mu      sync.Mutex
	queue   []update
	nextID  int64
	methods []string
	bodies  []map[string]any
}

func (f *fakeTelegram) push(u update) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.nextID++
	u.UpdateID = f.nextID
	f.queue = append(f.queue, u)
}

func (f *fakeTelegram) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	method := r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:]
	w.Header().Set("Content-Type", "application/json")
	if method == "getUpdates" {
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "result": f.queue})
		f.queue = nil
		return
	}
	var body map[string]any
	json.NewDecoder(r.Body).Decode(&body)
	f.methods = append(f.methods, method)
	f.bodies = append(f.bodies, body)
	w.Write([]byte(`{"ok":true,"result":{}}`))
}

// count compte les textes envoyés ou modifiés contenant want.
func (f *fakeTelegram) count(want string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, b := range f.bodies {
		if text, _ := b["text"].(string); strings.Contains(text, want) {
			n++
		}
	}
	return n
}

// said renvoie le dernier texte envoyé ou modifié contenant want, "" sinon.
func (f *fakeTelegram) said(want string) map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := len(f.bodies) - 1; i >= 0; i-- {
		if text, _ := f.bodies[i]["text"].(string); strings.Contains(text, want) {
			return f.bodies[i]
		}
	}
	return nil
}

type fixture struct {
	fake   *fakeTelegram
	bot    *Bot
	w      *watcher.Watcher
	tr     *requests.Tracker
	st     *store.Store
	dir    string
	offset atomic.Int64 // avance de l'horloge du bot
}

func newFixture(t *testing.T) *fixture {
	common := t.TempDir()
	dir := contract.AccountDirUnder(common, account)
	os.MkdirAll(dir, 0o755)
	b, err := os.ReadFile("../../../contract/examples/status.json")
	if err != nil {
		t.Fatal(err)
	}
	var s map[string]any
	json.Unmarshal(b, &s)
	s["ts"] = time.Now().UTC().Format(time.RFC3339)
	b, _ = json.Marshal(s)
	os.WriteFile(filepath.Join(dir, contract.StatusFile), b, 0o644)

	st, err := store.Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	tr, err := requests.New(st, common)
	if err != nil {
		t.Fatal(err)
	}
	w := watcher.New(common, func(a int64, e contract.Event, _ []byte, _ bool) { tr.OnEvent(a, e) })
	w.Poll()

	fake := &fakeTelegram{}
	srv := httptest.NewServer(fake)
	t.Cleanup(srv.Close)
	f := &fixture{fake: fake, w: w, tr: tr, st: st, dir: dir}
	f.bot = New(Config{Token: "T", Chats: map[int64][]int64{me: nil}, BaseURL: srv.URL}, w, tr, st)
	f.bot.now = func() time.Time { return time.Now().Add(time.Duration(f.offset.Load())) }
	return f
}

// advance avance l'horloge du bot.
func (f *fixture) advance(d time.Duration) { f.offset.Add(int64(d)) }

func (f *fixture) say(t *testing.T, chat int64, text string) {
	t.Helper()
	f.fake.push(update{Message: &message{MessageID: 1, Chat: chatRef{ID: chat}, From: &userRef{ID: chat, Username: "richmond"}, Text: text}})
	if err := f.bot.Poll(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
}

func (f *fixture) press(t *testing.T, data string) {
	t.Helper()
	f.fake.push(update{Callback: &callbackQuery{ID: "cb", Data: data, Message: &message{MessageID: 10, Chat: chatRef{ID: me}}}})
	if err := f.bot.Poll(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
}

// confirmButton renvoie le callback_data du bouton « Confirmer » du dernier /kill.
func (f *fixture) confirmButton(t *testing.T) string {
	t.Helper()
	return f.button(t, "Confirmer l'arrêt d'urgence")
}

// button renvoie le callback_data du premier bouton du dernier message contenant want.
func (f *fixture) button(t *testing.T, want string) string {
	t.Helper()
	data, _ := f.keyboard(t, want)
	return data
}

// keyboard renvoie le callback_data et le texte du premier bouton du dernier
// message contenant want.
func (f *fixture) keyboard(t *testing.T, want string) (data, text string) {
	t.Helper()
	body := f.fake.said(want)
	if body == nil {
		t.Fatalf("pas de message %q", want)
	}
	b, _ := json.Marshal(body["reply_markup"])
	var kb struct {
		Rows [][]struct {
			Text string `json:"text"`
			Data string `json:"callback_data"`
		} `json:"inline_keyboard"`
	}
	json.Unmarshal(b, &kb)
	if len(kb.Rows) == 0 || len(kb.Rows[0]) == 0 {
		t.Fatalf("message %q sans bouton", want)
	}
	return kb.Rows[0][0].Data, kb.Rows[0][0].Text
}

func TestUnauthorizedChat(t *testing.T) {
	f := newFixture(t)
	f.say(t, 999, "/kill")
	if f.fake.said("Chat non autorisé") == nil {
		t.Fatal("un chat inconnu doit être refusé")
	}
	if _, err := os.Stat(filepath.Join(f.dir, contract.KillFlag)); err == nil {
		t.Fatal("aucun drapeau ne doit partir d'un chat inconnu")
	}
}

// /kill, bouton « Confirmer », drapeau déposé, puis compte rendu quand le
// Watchdog répond dans son journal.
func TestKillWithConfirmation(t *testing.T) {
	f := newFixture(t)
	f.say(t, me, "/kill")
	if _, err := os.Stat(filepath.Join(f.dir, contract.KillFlag)); err == nil {
		t.Fatal("pas de drapeau avant la confirmation")
	}
	f.press(t, f.confirmButton(t))

	b, err := os.ReadFile(filepath.Join(f.dir, contract.KillFlag))
	if err != nil {
		t.Fatal("drapeau kill absent après la confirmation")
	}
	var flag contract.Request
	json.Unmarshal(b, &flag)
	if flag.Origin != "telegram" || flag.RequestID == "" {
		t.Fatalf("drapeau inattendu : %s", b)
	}

	line := fmt.Sprintf(`{"v":2,"seq":1,"ts":"%s","account":%d,"type":"kill","level":"critical","message":"ARRÊT : demande manuelle (telegram)","origin":"telegram","request_id":%q}`+"\n",
		time.Now().UTC().Format(time.RFC3339), account, flag.RequestID)
	os.WriteFile(filepath.Join(f.dir, contract.EventsFile), []byte(line), 0o644)
	f.w.Poll()

	deadline := time.Now().Add(5 * time.Second)
	for f.fake.said("Arrêt fait par la Mère") == nil {
		if time.Now().After(deadline) {
			t.Fatal("pas de compte rendu après la réponse du Watchdog")
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func TestCancelAndExpiry(t *testing.T) {
	f := newFixture(t)
	f.say(t, me, "/kill")
	data := f.confirmButton(t)
	f.press(t, "cancel:"+strings.TrimPrefix(data, "kill:"))
	if f.fake.said("Arrêt annulé") == nil {
		t.Fatal("annulation non confirmée")
	}
	f.press(t, data) // le jeton a été consommé par l'annulation
	if f.fake.said("Demande inconnue") == nil {
		t.Fatal("un bouton déjà utilisé ne doit plus rien faire")
	}

	f.say(t, me, "/kill")
	f.bot.now = func() time.Time { return time.Now().Add(2 * confirmWindow) }
	f.press(t, f.confirmButton(t))
	if f.fake.said("Confirmation expirée") == nil {
		t.Fatal("une confirmation trop tardive doit être refusée")
	}
	if _, err := os.Stat(filepath.Join(f.dir, contract.KillFlag)); err == nil {
		t.Fatal("aucun drapeau après annulation ou expiration")
	}
}

func TestStatusAndHelp(t *testing.T) {
	f := newFixture(t)
	f.say(t, me, "/etat")
	if body := f.fake.said("Solde 10480,00 &#183; filet de sécurité sur 3/3 position(s)"); body == nil || body["parse_mode"] != "HTML" {
		t.Fatal("/etat doit donner le solde du compte, en HTML")
	}
	if f.fake.said("<b>Robot en marche</b> : 3 position(s), résultat en cours -229,60 (la Mère coupe à -440)") == nil {
		t.Fatal("/etat doit dire l'état du robot en mots simples")
	}
	if f.fake.said("Caméléon (essai, ne ferme rien) : suit 1 groupe(s) en difficulté &#183; 2 bilan(s) : couper aurait coûté 41,30") == nil {
		t.Fatal("/etat doit montrer le Caméléon")
	}
	if f.fake.said("<b>PainX 2000</b> monte nettement (+0,6 % en 1 h), marché très nerveux &#183; contre le robot, qui y vend") == nil {
		t.Fatal("/etat doit donner le marché des symboles du robot")
	}
	f.say(t, me, "bonjour")
	if f.fake.said("/kill : arrêt d'urgence") == nil || f.fake.said("/relancer : après un arrêt") == nil || f.fake.said("/go : go-to-market") == nil ||
		f.fake.said("/actus : l'Actus du marché") == nil {
		t.Fatal("un message inconnu doit afficher l'aide")
	}
}

func TestParseChats(t *testing.T) {
	c, err := ParseChats("7805445021, -100222:123456+789")
	if err != nil || c[7805445021] != nil || len(c[-100222]) != 2 {
		t.Fatalf("ParseChats : %v %v", c, err)
	}
	if _, err := ParseChats("abc"); err == nil {
		t.Fatal("chat invalide accepté")
	}
}

// setStatus modifie le statut d'exemple, frais par défaut, et le fait relire.
func (f *fixture) setStatus(t *testing.T, change func(s map[string]any)) {
	t.Helper()
	path := filepath.Join(f.dir, contract.StatusFile)
	b, _ := os.ReadFile(path)
	var s map[string]any
	json.Unmarshal(b, &s)
	s["ts"] = f.bot.now().UTC().Format(time.RFC3339)
	change(s)
	b, _ = json.Marshal(s)
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
	f.w.Poll()
}

// killed : le compte d'exemple après un arrêt, positions fermées ; sans
// liste des symboles gardés (Watchdog d'avant 1.31) : go-to-market d'ensemble.
func killed(s map[string]any) {
	s["saved_symbols"] = []string{}
	s["targets"] = []any{}
	s["state"] = "KILL"
	s["positions"] = 0
	s["pending_orders"] = 0
	s["target_charts"] = 0
	s["saved_charts"] = 4
	s["daily_dd_pct"] = 1.2
	s["last_kill"] = map[string]any{"at": "2026-09-25T07:13:46Z", "reason": "perte flottante -440.37 (seuil -440.00)", "request_id": nil}
}

// answer joue le Watchdog : prend le drapeau et écrit l'événement qui y répond.
func (f *fixture) answer(t *testing.T, seq int, flagFile, typ, msg string) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(f.dir, flagFile))
	if err != nil {
		t.Fatalf("drapeau %s absent", flagFile)
	}
	os.Remove(filepath.Join(f.dir, flagFile))
	var req contract.Request
	json.Unmarshal(b, &req)
	line, _ := json.Marshal(map[string]any{"v": 2, "seq": seq, "ts": time.Now().UTC().Format(time.RFC3339), "account": account,
		"type": typ, "level": "info", "message": msg, "origin": "telegram", "request_id": req.RequestID})
	events, err := os.OpenFile(filepath.Join(f.dir, contract.EventsFile), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	events.Write(append(line, '\n'))
	events.Close()
	f.w.Poll()
}

func (f *fixture) exists(flagFile string) bool {
	_, err := os.Stat(filepath.Join(f.dir, flagFile))
	return err == nil
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal(what)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// /relancer après un arrêt : l'arrêt et le marché, le bouton, le réarmement,
// puis l'attente du marché, robot éteint : aucun RELANCER.
func TestRelaunchRearmsAndWaits(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, killed)
	f.say(t, me, "/relancer")

	body := f.fake.said("Relancer le robot ?")
	if body == nil {
		t.Fatal("pas de demande de confirmation")
	}
	text := body["text"].(string)
	for _, want := range []string{"perte flottante -440.37", "07:13 GMT", "PainX 2000", "+0,6 % en 1 h", "marché très nerveux",
		"Pas favorable", "PainX 2000 monte nettement (+0,6 % en 1 h), contre les ventes du robot", "laissera le robot éteint", "4 graphique(s)"} {
		if !strings.Contains(text, want) {
			t.Fatalf("confirmation sans %q :\n%s", want, text)
		}
	}
	data, button := f.keyboard(t, "Relancer le robot ?")
	if !strings.HasPrefix(data, "relaunch:") || button != "▶️ Réarmer et attendre le marché" || f.exists(contract.ResetFlag) {
		t.Fatalf("rien ne doit partir avant le bouton (%s, %s)", data, button)
	}

	f.press(t, data)
	waitFor(t, "drapeau reset absent après la confirmation", func() bool { return f.exists(contract.ResetFlag) })
	f.answer(t, 1, contract.ResetFlag, "reset", "RÉARMÉ (telegram)")
	waitFor(t, "attente du marché non annoncée", func() bool { return f.fake.said("Robot éteint, en attente du marché") != nil })
	if f.exists(contract.RelaunchFlag) {
		t.Fatal("le robot ne démarre que sur un go-to-market")
	}
	if saved, _ := f.st.Watches(); len(saved) != 1 || saved[0].Chat != me || saved[0].Account != account {
		t.Fatalf("attente non enregistrée : %+v", saved)
	}

	f.setStatus(t, armed(stormMarket)) // après le réarmement : état RUN, robot éteint
	f.say(t, me, "/etat")
	if f.fake.said("proposer de le relancer (depuis") == nil {
		t.Fatal("/etat doit montrer l'attente")
	}
	f.say(t, me, "/relancer")
	if f.fake.said("Déjà en attente du marché") == nil {
		t.Fatal("un second /relancer doit montrer l'attente en cours")
	}
}

// Un réarmement refusé par le Watchdog arrête tout : pas d'attente.
func TestRelaunchStopsWhenResetRefused(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, killed)
	f.say(t, me, "/relancer")
	f.press(t, f.button(t, "Relancer le robot ?"))
	waitFor(t, "drapeau reset absent", func() bool { return f.exists(contract.ResetFlag) })
	f.answer(t, 1, contract.ResetFlag, "reset_refused", "Réarmement refusé (telegram)\n1 position(s) et 0 ordre(s) encore ouverts.")
	waitFor(t, "refus non rapporté", func() bool { return f.fake.said("Réarmement refusé par la Mère") != nil })
	time.Sleep(300 * time.Millisecond)
	if _, ok := f.bot.watching(account); ok || f.exists(contract.RelaunchFlag) {
		t.Fatal("ni attente ni relance après un réarmement refusé")
	}
}

// Les cas où le Watchdog refuserait, ou recouperait aussitôt : réponse
// immédiate, aucun drapeau.
func TestRelaunchRefusedUpFront(t *testing.T) {
	cases := []struct {
		name, want string
		change     func(s map[string]any)
	}{
		{"positions ouvertes", "encore ouverts", func(s map[string]any) { killed(s); s["positions"] = 3 }},
		{"robot en marche", "tourne déjà", func(s map[string]any) {}},
		{"perte du jour", "recouperait aussitôt", func(s map[string]any) { killed(s); s["daily_dd_pct"] = 6.1 }},
		{"sans graphique", "à la main", func(s map[string]any) { killed(s); s["saved_charts"] = 0 }},
		{"Watchdog muet", "ne répond plus", func(s map[string]any) {
			killed(s)
			s["ts"] = time.Now().Add(-time.Minute).UTC().Format(time.RFC3339)
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newFixture(t)
			f.setStatus(t, c.change)
			f.say(t, me, "/relancer")
			if f.fake.said(c.want) == nil || f.fake.said("Relancer le robot ?") != nil {
				t.Fatalf("refus attendu (%q)", c.want)
			}
			if f.exists(contract.ResetFlag) || f.exists(contract.RelaunchFlag) {
				t.Fatal("aucun drapeau ne doit partir")
			}
		})
	}
}

// Le jeton d'une relance ne vaut pas pour un arrêt.
func TestButtonKindMustMatch(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, killed)
	f.say(t, me, "/relancer")
	token := strings.TrimPrefix(f.button(t, "Relancer le robot ?"), "relaunch:")
	f.press(t, "kill:"+token)
	if f.fake.said("Demande inconnue") == nil || f.exists(contract.KillFlag) || f.exists(contract.ResetFlag) {
		t.Fatal("un bouton d'un autre type ne doit rien faire")
	}
}

var (
	calmMarket = []map[string]any{{"symbol": "MAX PainX 2000", "price": 120000.0, "chg_1h_pct": 0.05,
		"chg_4h_pct": 0.10, "chg_24h_pct": 0.40, "trend": "neutre", "volatility": "normal"}}
	stormMarket = []map[string]any{{"symbol": "MAX PainX 2000", "price": 121300.0, "chg_1h_pct": 0.62,
		"chg_4h_pct": 1.10, "chg_24h_pct": 2.35, "trend": "hausse", "volatility": "agite"}}
)

// armed : compte réarmé, robot éteint, avec ce marché.
func armed(market []map[string]any) func(s map[string]any) {
	return func(s map[string]any) {
		killed(s)
		s["state"] = "RUN"
		s["market"] = market
	}
}

// tick : statut rafraîchi à l'heure du bot, puis un tour des attentes.
func (f *fixture) tick(t *testing.T, change func(s map[string]any)) {
	t.Helper()
	f.setStatus(t, change)
	f.bot.tickWatches(context.Background())
}

// Marché favorable 10 min d'affilée : go-to-market, et le robot ne démarre
// que sur le bouton.
func TestGoToMarketWhenFavorable(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, armed(calmMarket))
	f.bot.startWatch(context.Background(), me, account)
	if f.fake.said("Favorable</b>") == nil {
		t.Fatal("le premier point doit donner le verdict")
	}
	f.advance(5 * time.Minute)
	f.tick(t, armed(calmMarket))
	if f.fake.said("Go-to-market") != nil {
		t.Fatal("pas de go-to-market avant 10 min de marché favorable")
	}
	f.advance(6 * time.Minute)
	f.tick(t, armed(calmMarket))
	data, button := f.keyboard(t, "Go-to-market")
	if !strings.HasPrefix(data, "go:") || button != "▶️ Démarrer le robot" || f.exists(contract.RelaunchFlag) {
		t.Fatalf("go-to-market inattendu (%s, %s)", data, button)
	}

	f.press(t, data)
	waitFor(t, "drapeau relaunch absent après « Démarrer »", func() bool { return f.exists(contract.RelaunchFlag) })
	f.answer(t, 1, contract.RelaunchFlag, "relaunch", "RELANCE (telegram) : robot relancé\n4/4 graphique(s) rouvert(s), état RUN.")
	waitFor(t, "pas de compte rendu du démarrage", func() bool { return f.fake.said("Robot démarré</b>") != nil })
	waitFor(t, "l'attente doit se clore", func() bool { _, ok := f.bot.watching(account); return !ok })
	if saved, _ := f.st.Watches(); len(saved) != 0 {
		t.Fatalf("attente encore enregistrée : %+v", saved)
	}
}

// Go-to-market retiré si le marché se retourne ; après un retrait ou un
// « Pas maintenant », pas de nouvelle proposition avant 30 min.
func TestGoToMarketWithdrawnAndDeclined(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, armed(calmMarket))
	f.bot.startWatch(context.Background(), me, account)
	f.advance(11 * time.Minute)
	f.tick(t, armed(calmMarket))
	first := f.button(t, "Go-to-market")

	f.tick(t, armed(stormMarket))
	if f.fake.said("Go-to-market retiré") == nil {
		t.Fatal("un marché retourné doit retirer le go-to-market")
	}
	f.press(t, first)
	if f.fake.said("Demande inconnue") == nil || f.exists(contract.RelaunchFlag) {
		t.Fatal("un go-to-market retiré ne doit plus rien démarrer")
	}

	f.advance(time.Minute)
	f.tick(t, armed(calmMarket))
	f.advance(11 * time.Minute)
	f.tick(t, armed(calmMarket))
	if n := f.fake.count("Marché favorable depuis"); n != 1 {
		t.Fatalf("%d go-to-market, 1 attendu : 30 min entre deux propositions", n)
	}
	f.advance(20 * time.Minute) // 32 min après le premier
	f.tick(t, armed(calmMarket))
	second := f.button(t, "Marché favorable depuis")
	if second == first {
		t.Fatal("un nouveau go-to-market doit porter un nouveau jeton")
	}
	f.press(t, "cancel:"+strings.TrimPrefix(second, "go:"))
	if f.fake.said("reproposera dans 30 min") == nil {
		t.Fatal("« Pas maintenant » doit dire la suite")
	}
	f.tick(t, armed(calmMarket))
	if n := f.fake.count("Marché favorable depuis"); n != 2 || f.exists(contract.RelaunchFlag) {
		t.Fatalf("%d go-to-market après « Pas maintenant », 2 attendus", n)
	}
}

// Marché défavorable : pas de go-to-market, un point toutes les 2 h, fin
// après 24 h, robot toujours éteint.
func TestWatchUnfavorable(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, armed(stormMarket))
	f.bot.startWatch(context.Background(), me, account)
	for _, want := range []string{"Pas favorable", "PainX 2000 monte nettement (+1,1 % en 4 h)", "PainX 2000 très nerveux"} {
		if f.fake.said(want) == nil {
			t.Fatalf("premier point sans %q", want)
		}
	}
	f.advance(20 * time.Minute)
	f.tick(t, armed(stormMarket))
	if f.fake.said("Go-to-market") != nil || f.fake.said("Toujours en attente") != nil {
		t.Fatal("ni go-to-market ni point avant 2 h")
	}
	f.advance(2 * time.Hour)
	f.tick(t, armed(stormMarket))
	if f.fake.said("Toujours en attente du marché") == nil {
		t.Fatal("un point sur le marché toutes les 2 h")
	}
	f.advance(22 * time.Hour)
	f.tick(t, armed(stormMarket))
	if f.fake.said("Fin de l'attente après 24 h") == nil {
		t.Fatal("l'attente doit finir après 24 h")
	}
	if _, ok := f.bot.watching(account); ok || f.exists(contract.RelaunchFlag) {
		t.Fatal("attente close, robot toujours éteint")
	}
}

// L'attente se clôt si le robot démarre autrement, si le compte repasse en
// KILL, ou sur /annuler.
func TestWatchEnds(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	f.setStatus(t, armed(calmMarket))
	f.bot.startWatch(ctx, me, account)
	f.tick(t, func(s map[string]any) { armed(calmMarket)(s); s["target_charts"] = 1 })
	if _, ok := f.bot.watching(account); ok || f.fake.said("hors go-to-market") == nil {
		t.Fatal("robot démarré à la main : fin de l'attente")
	}

	f.setStatus(t, armed(calmMarket))
	f.bot.startWatch(ctx, me, account)
	f.advance(time.Minute)
	f.tick(t, func(s map[string]any) {
		killed(s)
		s["last_kill"] = map[string]any{"at": f.bot.now().UTC().Format(time.RFC3339), "reason": "perte flottante", "request_id": nil}
	})
	if _, ok := f.bot.watching(account); ok || f.fake.said("Attente interrompue") == nil {
		t.Fatal("nouvel arrêt : fin de l'attente")
	}

	f.setStatus(t, armed(calmMarket))
	f.bot.startWatch(ctx, me, account)
	f.say(t, me, "/annuler")
	if _, ok := f.bot.watching(account); ok || f.fake.said("Attente arrêtée") == nil {
		t.Fatal("/annuler doit clore l'attente")
	}
	if saved, _ := f.st.Watches(); len(saved) != 0 {
		t.Fatalf("attente encore enregistrée : %+v", saved)
	}
}

// Une attente survit au redémarrage de la passerelle.
func TestWatchSurvivesRestart(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, armed(stormMarket))
	f.bot.startWatch(context.Background(), me, account)
	again := New(Config{Token: "T", Chats: map[int64][]int64{me: nil}, BaseURL: "http://127.0.0.1:1"}, f.w, f.tr, f.st)
	if w, ok := again.watching(account); !ok || w.Chat != me || w.Since.IsZero() {
		t.Fatalf("attente perdue au redémarrage : %+v", w)
	}
}

// /go : go-to-market à la demande ; le bouton dit si le marché est défavorable.
func TestGoCommand(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, armed(stormMarket))
	f.say(t, me, "/go")
	if _, button := f.keyboard(t, "Go-to-market ?"); button != "▶️ Démarrer quand même" {
		t.Fatalf("bouton inattendu : %s", button)
	}
	f.setStatus(t, killed)
	f.say(t, me, "/go")
	if f.fake.said("/relancer d'abord") == nil {
		t.Fatal("en KILL, /go renvoie vers /relancer")
	}
}

// Une tendance ne gêne que contre le sens du robot ; sens inconnu ou mixte :
// toute tendance forte ; agité : jamais favorable.
func TestVerdictFollowsRobotSide(t *testing.T) {
	cases := []struct {
		trend, side, mood string
		favorable         bool
		reason            string
	}{
		{"baisse", "sell", "normal", true, ""},
		{"hausse", "buy", "calme", true, ""},
		{"hausse", "sell", "normal", false, "contre les ventes du robot"},
		{"baisse", "buy", "normal", false, "contre les achats du robot"},
		{"baisse", "both", "normal", false, "baisse nettement"},
		{"hausse", "", "normal", false, "monte nettement"},
		{"neutre", "", "agite", false, "très nerveux"},
		{"hausse", "buy", "agite", false, "très nerveux"},
	}
	for _, c := range cases {
		st := contract.Status{Market: []contract.Market{{Symbol: "MAX PainX 2000", Trend: c.trend, RobotSide: c.side, Volatility: c.mood}}}
		ok, reasons := verdict(st)
		if ok != c.favorable || (c.reason != "" && !strings.Contains(strings.Join(reasons, " "), c.reason)) {
			t.Fatalf("%s/%s/%s : favorable %v, raisons %v", c.trend, c.side, c.mood, ok, reasons)
		}
	}
	line := marketLines([]contract.Market{{Symbol: "MAX PainX 2000", Trend: "baisse", RobotSide: "sell", Volatility: "normal"}})
	if !strings.Contains(line, "bon pour le robot, qui y vend") {
		t.Fatalf("ligne de marché sans le sens du robot : %s", line)
	}
}

// Marché de la démo le 25/09 vers 11:15, sens du robot compris.
var demoMarket = []map[string]any{
	{"symbol": "MAX GainX 1000", "price": 59121.754, "chg_1h_pct": 0.25, "chg_4h_pct": -0.16, "chg_24h_pct": -1.88,
		"trend": "neutre", "volatility": "normal", "robot_side": "buy"},
	{"symbol": "MAX PainX 2000", "price": 116261.487, "chg_1h_pct": -0.44, "chg_4h_pct": -3.01, "chg_24h_pct": -5.96,
		"trend": "baisse", "volatility": "normal", "robot_side": "sell"},
	{"symbol": "MAX GainX 2000", "price": 83724.0, "chg_1h_pct": 0.21, "chg_4h_pct": -1.6, "chg_24h_pct": -3.21,
		"trend": "baisse", "volatility": "agite", "robot_side": "buy"},
}

// L'actus parle en mots simples, du plus inquiétant au plus calme.
func TestActusPlainLanguage(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, armed(demoMarket))
	text, ok := f.bot.actusText(account, f.bot.now())
	if !ok {
		t.Fatal("pas d'actus avec un marché frais")
	}
	for _, want := range []string{
		"L'Actus du marché",
		"<blockquote>&#x26C8;&#xFE0F; <b>Marché nerveux</b>\nGrands mouvements sur GainX 2000 : prudence.</blockquote>",
		"<b>PainX 2000</b> baisse nettement (-3,0 % en 4 h, -6,0 % sur 24 h). Mouvements habituels.",
		"<i>Bon pour le robot, qui y vend.</i>",
		"<b>GainX 1000</b> reste stable (-0,2 % en 4 h, -1,9 % sur 24 h)",
		"<i>Le robot y achète : rien à signaler.</i>",
		"<i>Contre le robot, qui y achète.</i>",
		"Marché très nerveux, avec de grands écarts.",
		"<b>Robot éteint</b>",
		"/actus off",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("actus sans %q :\n%s", want, text)
		}
	}
	// M5, M30, H1 ne sont plus du jargon : le trader les veut (25/09).
	for _, jargon := range []string{"ATR", "volatil", "tendance forte"} {
		if strings.Contains(text, jargon) {
			t.Fatalf("jargon %q dans l'actus :\n%s", jargon, text)
		}
	}
	if strings.Index(text, "GainX 2000") > strings.Index(text, "PainX 2000") || strings.Index(text, "PainX 2000</b>") > strings.Index(text, "GainX 1000</b>") {
		t.Fatalf("le plus inquiétant d'abord :\n%s", text)
	}

	f.setStatus(t, func(s map[string]any) { armed(demoMarket)(s); s["state"] = "KILL" })
	if text, _ := f.bot.actusText(account, f.bot.now()); !strings.Contains(text, "<b>Robot arrêté</b> par la Mère (perte flottante -440.37 (seuil -440.00))") {
		t.Fatalf("état du robot absent :\n%s", text)
	}
	f.setStatus(t, func(s map[string]any) {
		armed(demoMarket)(s)
		s["ts"] = time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
	})
	if _, ok := f.bot.actusText(account, f.bot.now()); ok {
		t.Fatal("pas d'actus sans statut frais")
	}
}

// /actus à la demande ; /actus off coupe la publication, /actus on la reprend.
func TestActusCommandAndPublish(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	f.setStatus(t, armed(demoMarket))
	f.say(t, me, "/actus")
	if f.fake.count("L'Actus du marché") != 1 {
		t.Fatal("/actus doit publier tout de suite")
	}
	f.say(t, me, "/actus off")
	if f.fake.said("Actus du marché coupée") == nil {
		t.Fatal("/actus off doit confirmer")
	}
	if v, _ := f.st.ChatPref(me, "actus"); v != "off" {
		t.Fatalf("préférence non enregistrée : %q", v)
	}
	f.bot.publishActus(ctx)
	if n := f.fake.count("L'Actus du marché"); n != 1 {
		t.Fatalf("%d actus après /actus off, 1 attendue", n)
	}
	f.say(t, me, "/actus on")
	f.bot.publishActus(ctx)
	if n := f.fake.count("L'Actus du marché"); n != 2 {
		t.Fatalf("%d actus après /actus on, 2 attendues", n)
	}
}

// Sans le sens du robot (Watchdog antérieur à 1.27), l'actus ne prétend
// pas savoir si un mouvement l'aide ou le gêne.
func TestActusWithoutRobotSide(t *testing.T) {
	cases := []struct {
		trend, side, mood string
		want              weather
	}{
		{"baisse", "", "normal", windy},
		{"hausse", "both", "normal", windy},
		{"baisse", "sell", "normal", good},
		{"baisse", "buy", "normal", rain},
		{"neutre", "", "calme", calm},
		{"hausse", "", "agite", storm},
	}
	for _, c := range cases {
		if got := weatherOf(contract.Market{Trend: c.trend, RobotSide: c.side, Volatility: c.mood}); got != c.want {
			t.Fatalf("%s/%s/%s : météo %d, %d attendue", c.trend, c.side, c.mood, got, c.want)
		}
	}
	f := newFixture(t)
	f.setStatus(t, armed([]map[string]any{{"symbol": "MAX PainX 2000", "price": 1.0, "chg_1h_pct": -1.35, "chg_4h_pct": -4.75,
		"chg_24h_pct": -8.06, "trend": "baisse", "volatility": "normal"}}))
	text, _ := f.bot.actusText(account, f.bot.now())
	if !strings.Contains(text, "<b>Ça bouge</b>\nMouvement marqué sur PainX 2000") || strings.Contains(text, "contre le robot</i>") ||
		strings.Contains(text, "Contre le robot") {
		t.Fatalf("sans sens connu, ni « contre » ni « bon pour » le robot :\n%s", text)
	}
}

func TestNextActus(t *testing.T) {
	for in, want := range map[string]string{"11:14:23": "11:30:00", "11:30:00": "12:00:00", "23:59:59": "00:00:00"} {
		now, _ := time.Parse("15:04:05", in)
		if got := nextActus(now).Format("15:04:05"); got != want {
			t.Fatalf("après %s : %s, %s attendu", in, got, want)
		}
	}
}

// Le diagnostic 24 h en langage simple : les points à corriger d'abord, que
// faire en clics, la commande à part pour les initiés, puis ce qui va bien.
func TestReadinessPlainLanguage(t *testing.T) {
	r := readiness.Report{Checks: []readiness.Check{
		{ID: "sleep", Label: "Mise en veille", Level: readiness.Warning,
			Detail: "Branché, l'ordinateur ne se met jamais en veille : très bien.", Fix: "Laisser l'ordinateur branché en permanence.",
			Tech: "powercfg /change standby-timeout-dc 0"},
		{ID: "power", Label: "Branchement", Level: readiness.OK, Detail: "L'ordinateur est branché sur le secteur."},
		{ID: "autologon", Label: "Redémarrage sans mot de passe", Level: readiness.Error,
			Detail: "L'ordinateur redémarre puis attend le mot de passe.", Fix: "Installer l'outil gratuit Autologon de Microsoft."},
		{ID: "mt5_startup", Label: "MT5 au démarrage", Level: readiness.OK},
	}}
	text := ReadinessMessage(r)
	for _, want := range []string{
		"<b>L'ordinateur peut-il veiller 24 h sur 24 ?</b>\nPas encore : 1 point à corriger, 1 point à surveiller.",
		"&#x274C; <b>Redémarrage sans mot de passe</b> &#183; à corriger\nL&#39;ordinateur redémarre puis attend le mot de passe.",
		"&#x1F449; <b>Que faire :</b> Laisser l&#39;ordinateur branché en permanence.",
		"<i>Pour les initiés :</i> <code>powercfg /change standby-timeout-dc 0</code>",
		"&#x2705; <b>Déjà en ordre :</b> Branchement, MT5 au démarrage.",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("diagnostic sans %q :\n%s", want, text)
		}
	}
	if strings.Index(text, "Redémarrage sans mot de passe") > strings.Index(text, "Mise en veille") {
		t.Fatalf("les points à corriger d'abord :\n%s", text)
	}
	all := ReadinessMessage(readiness.Report{Checks: []readiness.Check{{Label: "Branchement", Level: readiness.OK}}})
	if !strings.Contains(all, "L'ordinateur est prêt à veiller 24 h sur 24") || !strings.Contains(all, "Vérifié : Branchement.") {
		t.Fatalf("tout en ordre :\n%s", all)
	}
}

// fakeCaller imite CallMeBot : il note chaque appel.
type fakeCaller struct {
	mu    sync.Mutex
	calls [][2]string // qui, texte
	err   error
}

func (c *fakeCaller) Call(_ context.Context, user, text string) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.calls = append(c.calls, [2]string{user, text})
	return "Call queued", c.err
}

func (c *fakeCaller) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.calls)
}

func (f *fixture) armPreAlert() *fakeCaller {
	c := &fakeCaller{}
	f.bot.cfg.PreAlert = 300
	f.bot.cfg.Caller = c
	return c
}

// loss : le compte d'exemple, robot en marche, avec cette perte en cours.
func loss(v float64) func(s map[string]any) {
	return func(s map[string]any) {
		s["floating"] = v
		s["positions"] = 4
		s["symbols"] = []map[string]any{
			{"symbol": "MAX GainX 2000", "positions": 3, "buy_volume": 0.6, "sell_volume": 0.0, "floating": v + 20},
			{"symbol": "MAX PainX 2000", "positions": 1, "buy_volume": 0.0, "sell_volume": 0.2, "floating": -20.0},
		}
	}
}

func (f *fixture) tickLoss(t *testing.T, v float64) {
	t.Helper()
	f.setStatus(t, loss(v))
	f.bot.tickPreAlerts(context.Background())
}

// -300 : alerte et boutons ; sans « J'ai vu » en 2 min, appel, puis toutes
// les 5 min ; « J'ai vu » arrête les appels ; l'alerte se lève à -250.
func TestPreAlertCallsUntilSeen(t *testing.T) {
	f := newFixture(t)
	c := f.armPreAlert()
	f.say(t, me, "/etat") // la Mère apprend le @nom du chat
	f.tickLoss(t, -250)
	if f.fake.said("ALERTE") != nil {
		t.Fatal("pas d'alerte avant -300")
	}
	f.tickLoss(t, -305)
	body := f.fake.said("ALERTE : perte en cours -305,00")
	if body == nil {
		t.Fatal("pas d'alerte à -305")
	}
	text := body["text"].(string)
	for _, want := range []string{"il reste 135,00 avant l'arrêt d'urgence", "4 position(s) ouverte(s) ; la plus touchée : GainX 2000 (achats), -285,00",
		"Sans « J'ai vu » dans 2 min, la Mère appelle sur Telegram."} {
		if !strings.Contains(text, want) {
			t.Fatalf("alerte sans %q :\n%s", want, text)
		}
	}
	seen, button := f.keyboard(t, "ALERTE : perte en cours")
	if !strings.HasPrefix(seen, "seen:") || button != "✅ J'ai vu" || c.count() != 0 {
		t.Fatalf("boutons inattendus (%s, %s) ou appel trop tôt", seen, button)
	}

	f.advance(time.Minute)
	f.tickLoss(t, -320)
	if c.count() != 0 {
		t.Fatal("pas d'appel avant 2 min")
	}
	f.advance(time.Minute + time.Second)
	f.tickLoss(t, -320)
	if c.count() != 1 || c.calls[0][0] != "@richmond" || !strings.Contains(c.calls[0][1], "perd 320") {
		t.Fatalf("premier appel inattendu : %v", c.calls)
	}
	if f.fake.said("Appel n°1") == nil {
		t.Fatal("l'appel doit être annoncé dans le chat")
	}
	f.advance(time.Minute)
	f.tickLoss(t, -320)
	f.advance(5 * time.Minute)
	f.tickLoss(t, -320)
	if c.count() != 2 {
		t.Fatalf("%d appels, 2 attendus : un toutes les 5 min", c.count())
	}

	f.press(t, seen)
	if f.fake.said("Vu à") == nil {
		t.Fatal("« J'ai vu » doit être confirmé")
	}
	f.advance(6 * time.Minute)
	f.tickLoss(t, -330)
	if c.count() != 2 {
		t.Fatal("plus d'appel après « J'ai vu »")
	}

	f.tickLoss(t, -240)
	if f.fake.said("Alerte levée") == nil {
		t.Fatal("l'alerte se lève au-dessus de -250")
	}
	f.tickLoss(t, -310)
	if n := f.fake.count("ALERTE : perte en cours"); n != 2 {
		t.Fatalf("%d alertes, 2 attendues après une nouvelle descente", n)
	}
}

// L'arrêt d'urgence clôt l'alerte sans message de plus : il a le sien.
func TestPreAlertEndsOnKill(t *testing.T) {
	f := newFixture(t)
	f.armPreAlert()
	f.tickLoss(t, -305)
	f.setStatus(t, func(s map[string]any) { killed(s); s["floating"] = 0.0 })
	f.bot.tickPreAlerts(context.Background())
	if f.fake.said("Alerte levée") != nil || len(f.bot.preAlerts) != 0 {
		t.Fatal("après l'arrêt, l'alerte se clôt en silence")
	}
}

// « Tout arrêter » vaut « J'ai vu » et propose l'arrêt d'urgence, confirmé à part.
func TestPreAlertStopButton(t *testing.T) {
	f := newFixture(t)
	f.armPreAlert()
	f.tickLoss(t, -305)
	seen := f.button(t, "ALERTE : perte en cours")
	f.press(t, "stop:"+strings.TrimPrefix(seen, "seen:"))
	if f.fake.said("Vu à") == nil || f.fake.said("Confirmer l'arrêt d'urgence") == nil {
		t.Fatal("« Tout arrêter » doit arrêter les appels et demander confirmation")
	}
	if f.exists(contract.KillFlag) {
		t.Fatal("aucun arrêt sans la confirmation")
	}
}

// /appel : qui est appelé, test, erreur du service, off, autre numéro.
func TestCallCommand(t *testing.T) {
	f := newFixture(t)
	c := f.armPreAlert()
	f.say(t, me, "/appel")
	if body := f.fake.said("Appel d'alerte"); body == nil || !strings.Contains(body["text"].(string), "<b>@richmond</b>") {
		t.Fatal("/appel doit dire qui est appelé")
	}
	f.say(t, me, "/appel test")
	if c.count() != 1 || f.fake.said("Appel de test lancé") == nil {
		t.Fatal("/appel test doit appeler")
	}
	c.err = errors.New("CallMeBot n'a pas lancé l'appel : You need to authorize CallMeBot")
	f.say(t, me, "/appel test")
	if f.fake.said("Appel de test impossible") == nil || f.fake.said("/start à @CallMeBot_txtbot") == nil {
		t.Fatal("un refus du service doit expliquer quoi faire")
	}
	c.err = nil
	f.say(t, me, "/appel +2250700000000")
	if f.bot.callTarget(me) != "+2250700000000" {
		t.Fatalf("numéro non retenu : %q", f.bot.callTarget(me))
	}

	f.say(t, me, "/appel off")
	f.tickLoss(t, -305)
	f.advance(3 * time.Minute)
	f.tickLoss(t, -305)
	if c.count() != 2 {
		t.Fatalf("%d appels : aucun appel quand /appel off", c.count())
	}
}

func TestPreAlertLevelBelowLimit(t *testing.T) {
	b := &Bot{cfg: Config{PreAlert: 300}}
	if l := b.preAlertLevel(contract.Status{Config: contract.Config{MaxFloatingLoss: 440}}); l != 300 {
		t.Fatalf("seuil %v, 300 attendu", l)
	}
	if l := b.preAlertLevel(contract.Status{Config: contract.Config{MaxFloatingLoss: 250}}); l != 175 {
		t.Fatalf("seuil %v, 175 attendu : sous la limite d'arrêt", l)
	}
}

// Pause d'une heure après un arrêt : /go refusé avec l'heure de reprise,
// pas de go-to-market avant la fin de la pause, même marché favorable.
func TestPauseAfterKill(t *testing.T) {
	f := newFixture(t)
	justKilled := func(s map[string]any) {
		armed(calmMarket)(s)
		s["last_kill"] = map[string]any{"at": f.bot.now().Add(-10 * time.Minute).UTC().Format(time.RFC3339), "reason": "perte en cours -440.60", "request_id": nil}
	}
	f.setStatus(t, justKilled)
	f.say(t, me, "/go")
	if body := f.fake.said("Pause après l'arrêt d'urgence"); body == nil || !strings.Contains(body["text"].(string), "avant "+gmt(f.bot.now().Add(50 * time.Minute).Truncate(time.Second))[:2]) {
		t.Fatal("/go doit être refusé pendant la pause, avec l'heure de reprise")
	}
	if f.fake.said("Go-to-market ?") != nil {
		t.Fatal("pas de bouton Démarrer pendant la pause")
	}

	f.bot.startWatch(context.Background(), me, account)
	if f.fake.said("pas de démarrage avant") == nil {
		t.Fatal("l'attente doit annoncer la pause")
	}
	keep := f.bot.now().Add(-10 * time.Minute) // l'arrêt ne bouge pas quand l'horloge avance
	fixed := func(s map[string]any) {
		armed(calmMarket)(s)
		s["last_kill"] = map[string]any{"at": keep.UTC().Format(time.RFC3339), "reason": "perte en cours -440.60", "request_id": nil}
	}
	f.advance(11 * time.Minute)
	f.tick(t, fixed)
	f.advance(20 * time.Minute)
	f.tick(t, fixed)
	if f.fake.said("Go-to-market</b>") != nil {
		t.Fatal("pas de go-to-market pendant la pause")
	}
	f.advance(20 * time.Minute) // 51 min plus tard : la pause est finie
	f.tick(t, fixed)
	if f.fake.said("Marché favorable depuis") == nil {
		t.Fatal("le go-to-market arrive après la pause")
	}
}

// L'Actus montre la règle du trader, le bilan du jour et celui du Caméléon.
func TestActusRuleDayAndChameleon(t *testing.T) {
	f := newFixture(t)
	market := []map[string]any{
		{"symbol": "MAX GainX 2000", "price": 1.0, "chg_1h_pct": -0.3, "chg_4h_pct": -1.5, "chg_24h_pct": -3.0, "trend": "baisse",
			"volatility": "normal", "robot_side": "buy", "want": "buy", "m5": "baisse", "m30": "baisse", "h1": "neutre", "rule": "interdit"},
		{"symbol": "MAX PainX 2000", "price": 1.0, "chg_1h_pct": -0.4, "chg_4h_pct": -3.0, "chg_24h_pct": -6.0, "trend": "baisse",
			"volatility": "normal", "robot_side": "sell", "want": "sell", "m5": "baisse", "m30": "baisse", "h1": "baisse", "rule": "autorise", "reversal": true},
	}
	f.setStatus(t, func(s map[string]any) {
		armed(market)(s)
		s["equity"], s["floating"], s["positions"] = 7643.15, 0.0, 2
		s["symbols"] = []map[string]any{{"symbol": "MAX PainX 2000", "positions": 2, "buy_volume": 0.0, "sell_volume": 0.4, "floating": 0.0}}
	})
	day := f.bot.now().UTC().Truncate(24 * time.Hour)
	f.st.AddSample(account, day.Add(5*time.Minute), 8171.71, 8171.71)
	for i, ev := range []map[string]any{{"type": "kill", "rule": "manual"}, {"type": "relaunch"}, {"type": "kill", "rule": "floating_loss"}, {"type": "chameleon"},
		{"type": "chameleon_outcome", "saved": -155.04}, {"type": "kill", "old": true}} {
		ts := day.Add(time.Duration(i+1) * time.Minute)
		if ev["old"] == true {
			ts = day.Add(-time.Hour) // hier : ne compte pas
		}
		raw, _ := json.Marshal(ev)
		f.st.AddEvent(account, int64(i+1), ts, ev["type"].(string), raw)
	}
	text, ok := f.bot.actusText(account, f.bot.now())
	if !ok {
		t.Fatal("pas d'actus")
	}
	for _, want := range []string{
		"Ta règle : <b>AUTORISÉ</b> sur PainX 2000 ; INTERDIT sur GainX 2000.",
		"&#x1F534; <b>INTERDIT</b> &#183; M5 &#x2198;&#xFE0F; baisse &#183; M30 &#x2198;&#xFE0F; baisse &#183; H1 &#x27A1;&#xFE0F; neutre\n" +
			"<i>M5 va contre le robot. Pour le &#x1F7E2; : M5 en hausse, avec M30 ou H1 en hausse.</i>",
		"&#x1F7E2; <b>AUTORISÉ</b> &#183; M5 &#x2198;&#xFE0F; baisse &#183; M30 &#x2198;&#xFE0F; baisse &#183; H1 &#x2198;&#xFE0F; baisse\n" +
			"<i>M5, M30 et H1 vont dans le sens du robot.</i>",
		"<b>Retournement</b> : forte bougie M5 contre le robot, positions ouvertes.",
		"<b>Aujourd'hui</b> : 2 arrêt(s) d'urgence (dont 1 demandé(s) à la main), 1 relance(s) &#183; résultat du jour -528,56.",
		"<b>Caméléon</b> (essai, ne ferme rien) : aujourd'hui 1 cas, 1 bilan(s) : couper aurait coûté 155,04",
		"Depuis le début : contre-tendance 1 cas, couper aurait coûté 141,50 ; perte lourde 1 cas, couper aurait épargné 100,20.",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("actus sans %q :\n%s", want, text)
		}
	}
}

// ruled : robot éteint (réarmé) sur GainX 2000 et PainX 2000, gardés tous les
// deux ; la règle dit ruleGainX et rulePainX.
func ruled(ruleGainX, rulePainX string, open ...string) func(s map[string]any) {
	return func(s map[string]any) {
		killed(s)
		s["state"] = "RUN"
		s["saved_symbols"] = []string{"MAX GainX 2000", "MAX PainX 2000"}
		s["saved_charts"] = 2
		var targets []map[string]any
		for _, o := range open {
			targets = append(targets, map[string]any{"expert": "LE RECUPERATEUR V44.5", "symbol": o, "period": "H1", "inputs": map[string]any{}})
		}
		s["targets"] = targets
		s["target_charts"] = len(open)
		s["market"] = []map[string]any{
			{"symbol": "MAX GainX 2000", "price": 1.0, "chg_1h_pct": -0.3, "chg_4h_pct": -1.5, "chg_24h_pct": -3.0, "trend": "baisse",
				"volatility": "normal", "robot_side": "buy", "want": "buy", "m5": "baisse", "m30": "baisse", "h1": "neutre", "rule": ruleGainX},
			{"symbol": "MAX PainX 2000", "price": 1.0, "chg_1h_pct": -0.4, "chg_4h_pct": -3.0, "chg_24h_pct": -6.0, "trend": "baisse",
				"volatility": "normal", "robot_side": "sell", "want": "sell", "m5": "baisse", "m30": "baisse", "h1": "baisse", "rule": rulePainX},
		}
	}
}

// Go-to-market par symbole : seuls les 🟢 sont proposés, et seul leur
// graphique est rouvert ; un 🔴 est proposé quand il passe au 🟢.
func TestGoToMarketPerSymbol(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, ruled("interdit", "autorise"))
	f.bot.startWatch(context.Background(), me, account)
	if f.fake.said("en attente de ta règle") == nil {
		t.Fatal("l'attente doit annoncer le mode par symbole")
	}
	f.tick(t, ruled("interdit", "autorise"))
	body := f.fake.said("Go-to-market</b>")
	if body == nil || !strings.Contains(body["text"].(string), "sur PainX 2000 : la Mère propose") ||
		!strings.Contains(body["text"].(string), "Restent éteints : GainX 2000.") {
		t.Fatalf("proposition inattendue : %v", body)
	}
	data, button := f.keyboard(t, "Go-to-market</b>")
	if button != "▶️ Démarrer PainX 2000" || !strings.HasPrefix(data, "gosym:") {
		t.Fatalf("bouton inattendu : %s %s", button, data)
	}
	f.press(t, data)
	waitFor(t, "drapeau relaunch absent", func() bool { return f.exists(contract.RelaunchFlag) })
	raw, _ := os.ReadFile(filepath.Join(f.dir, contract.RelaunchFlag))
	var flag map[string]any
	json.Unmarshal(raw, &flag)
	if syms, _ := flag["symbols"].([]any); len(syms) != 1 || syms[0] != "MAX PainX 2000" {
		t.Fatalf("seul PainX 2000 doit être relancé : %s", raw)
	}
	f.answer(t, 1, contract.RelaunchFlag, "relaunch", "ROBOT RELANCÉ (depuis Telegram) sur PainX 2000")
	waitFor(t, "pas de compte rendu", func() bool { return f.fake.said("Démarré : PainX 2000") != nil })

	f.advance(time.Minute)
	f.tick(t, ruled("interdit", "autorise", "MAX PainX 2000"))
	if n := f.fake.count("Go-to-market</b>"); n != 1 {
		t.Fatalf("%d propositions : GainX 2000 reste 🔴", n)
	}
	f.advance(time.Minute)
	f.tick(t, ruled("autorise", "autorise", "MAX PainX 2000"))
	if _, button := f.keyboard(t, "Go-to-market</b>"); button != "▶️ Démarrer GainX 2000" {
		t.Fatalf("GainX 2000 passé au 🟢 doit être proposé : %s", button)
	}
	f.tick(t, ruled("autorise", "autorise", "MAX PainX 2000", "MAX GainX 2000"))
	if _, ok := f.bot.watching(account); ok || f.fake.said("Robot en marche sur tous ses symboles") == nil {
		t.Fatal("tous les symboles en marche : fin de l'attente")
	}
}

// Une proposition est retirée si son symbole repasse au 🔴 ; le bouton ne
// démarre plus rien.
func TestGoToMarketPerSymbolWithdrawn(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, ruled("interdit", "autorise"))
	f.bot.startWatch(context.Background(), me, account)
	f.tick(t, ruled("interdit", "autorise"))
	data := f.button(t, "Go-to-market</b>")
	f.tick(t, ruled("interdit", "interdit"))
	if f.fake.said("Go-to-market retiré") == nil {
		t.Fatal("retour au 🔴 : proposition retirée")
	}
	f.press(t, data)
	if f.fake.said("Demande inconnue") == nil || f.exists(contract.RelaunchFlag) {
		t.Fatal("un bouton retiré ne démarre rien")
	}
}

// Robot en marche sur une partie de ses symboles : la relance reste possible.
func TestRelaunchPlanPartial(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, ruled("interdit", "autorise", "MAX PainX 2000"))
	snap, _ := f.w.Snapshot(account)
	if _, refusal := relaunchPlan(snap.Status, f.bot.now()); refusal != "" {
		t.Fatalf("GainX 2000 éteint : relance possible, refus %q", refusal)
	}
	f.setStatus(t, ruled("interdit", "autorise", "MAX PainX 2000", "MAX GainX 2000"))
	snap, _ = f.w.Snapshot(account)
	if _, refusal := relaunchPlan(snap.Status, f.bot.now()); !strings.Contains(refusal, "tourne déjà") {
		t.Fatalf("tout en marche : refus attendu, %q", refusal)
	}
}

// Sans les tendances (Watchdog d'avant 1.30), l'Actus et /etat disent
// comment les obtenir ; avec, /etat les montre sous chaque symbole.
func TestTrendsShownOrExplained(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, armed(demoMarket)) // marché sans règle : Watchdog trop ancien
	text, _ := f.bot.actusText(account, f.bot.now())
	if !strings.Contains(text, "Tendances M5, M30, H1 et ta règle : remettre MerePoule sur son graphique") {
		t.Fatalf("l'Actus doit dire comment voir les tendances :\n%s", text)
	}
	f.setStatus(t, ruled("interdit", "autorise"))
	f.say(t, me, "/etat")
	body := f.fake.said("Solde")
	if body == nil || !strings.Contains(body["text"].(string), "&#x1F7E2; <b>AUTORISÉ</b> &#183; M5 &#x2198;&#xFE0F; baisse") ||
		strings.Contains(body["text"].(string), "remettre MerePoule") {
		t.Fatalf("/etat doit montrer les tendances et le verdict : %v", body)
	}
}

// manual : décision manuelle à -440, arrêt automatique à -880 (Watchdog 1.32).
func manual(s map[string]any) {
	c := s["config"].(map[string]any)
	c["manual_decision"] = true
	c["floating_last_resort"] = 880.0
}

func manualLoss(v float64) func(s map[string]any) {
	return func(s map[string]any) { loss(v)(s); manual(s) }
}

// À -440 en décision manuelle : alerte DÉCISION, appel tout de suite,
// « Laisser courir » arrête les appels.
func TestDecisionAtLimit(t *testing.T) {
	f := newFixture(t)
	c := f.armPreAlert()
	f.say(t, me, "/etat")
	f.setStatus(t, manualLoss(-445))
	f.bot.tickPreAlerts(context.Background())
	body := f.fake.said("DÉCISION À PRENDRE : perte en cours -445,00")
	if body == nil || !strings.Contains(body["text"].(string), "Sans décision, elle coupera tout à -880 (il reste 435,00).") {
		t.Fatalf("alerte de décision inattendue : %v", body)
	}
	stop, button := f.keyboard(t, "DÉCISION À PRENDRE")
	if button != "🛑 Tout arrêter" || !strings.HasPrefix(stop, "stop:") {
		t.Fatalf("bouton inattendu : %s", button)
	}
	f.bot.tickPreAlerts(context.Background())
	if c.count() != 1 || !strings.Contains(c.calls[0][1], "Décision Mère Poule") {
		t.Fatalf("l'appel doit partir tout de suite : %v", c.calls)
	}
	f.press(t, "seen:"+strings.TrimPrefix(stop, "stop:"))
	if f.fake.said("Tu laisses courir") == nil || f.fake.said("la Mère coupera tout seule à -880") == nil {
		t.Fatal("« Laisser courir » doit être confirmé")
	}
	f.advance(6 * time.Minute)
	f.setStatus(t, manualLoss(-460))
	f.bot.tickPreAlerts(context.Background())
	if c.count() != 1 {
		t.Fatal("plus d'appel après « Laisser courir »")
	}
}

// Une alerte à -300 déjà vue passe au niveau décision à -440 : nouvel
// appel, même si « J'ai vu » avait été pressé.
func TestDecisionAfterPreAlert(t *testing.T) {
	f := newFixture(t)
	c := f.armPreAlert()
	f.say(t, me, "/etat")
	f.setStatus(t, manualLoss(-305))
	f.bot.tickPreAlerts(context.Background())
	body := f.fake.said("ALERTE : perte en cours -305,00")
	if body == nil || !strings.Contains(body["text"].(string), "À -440, c'est toi qui décides ; la Mère ne coupe seule qu'à -880.") {
		t.Fatalf("pré-alerte inattendue : %v", body)
	}
	f.press(t, f.button(t, "ALERTE : perte en cours"))
	f.setStatus(t, manualLoss(-441))
	f.bot.tickPreAlerts(context.Background())
	f.bot.tickPreAlerts(context.Background())
	if f.fake.said("DÉCISION À PRENDRE") == nil || c.count() != 1 {
		t.Fatalf("passage au seuil de décision : alerte et appel attendus (%d appel(s))", c.count())
	}
}

// Retournement sur un symbole avec positions : alerte, « Couper » écrit
// cut.flag pour ce seul symbole ; pas de doublon dans les 15 min.
func TestReversalAlertAndCut(t *testing.T) {
	f := newFixture(t)
	reversal := func(s map[string]any) {
		ruled("autorise", "interdit", "MAX GainX 2000", "MAX PainX 2000")(s)
		m := s["market"].([]map[string]any)
		m[0]["reversal"] = true
		s["positions"] = 3
		s["symbols"] = []map[string]any{{"symbol": "MAX GainX 2000", "positions": 3, "buy_volume": 0.6, "sell_volume": 0.0, "floating": -185.4}}
	}
	f.setStatus(t, reversal)
	f.bot.tickPreAlerts(context.Background())
	body := f.fake.said("RETOURNEMENT")
	if body == nil || !strings.Contains(body["text"].(string), "sur <b>GainX 2000</b>, qui y achète : 3 position(s), -185,40.") {
		t.Fatalf("alerte de retournement inattendue : %v", body)
	}
	data, button := f.keyboard(t, "RETOURNEMENT")
	if button != "🛑 Couper GainX 2000" || !strings.HasPrefix(data, "cut:") {
		t.Fatalf("bouton inattendu : %s %s", button, data)
	}
	f.bot.tickPreAlerts(context.Background())
	if n := f.fake.count("RETOURNEMENT"); n != 1 {
		t.Fatalf("%d alertes : pas de doublon", n)
	}
	f.press(t, data)
	waitFor(t, "cut.flag absent", func() bool { return f.exists(contract.CutFlag) })
	if f.exists(contract.KillFlag) {
		t.Fatal("couper un symbole ne doit jamais tout arrêter")
	}
	raw, _ := os.ReadFile(filepath.Join(f.dir, contract.CutFlag))
	var c contract.CutRequest
	json.Unmarshal(raw, &c)
	if c.Symbol != "MAX GainX 2000" {
		t.Fatalf("cut.flag inattendu : %s", raw)
	}
	f.answer(t, 1, contract.CutFlag, "symbol_cut", "SYMBOLE COUPÉ : GainX 2000 (depuis Telegram)")
	waitFor(t, "compte rendu absent", func() bool { return f.fake.said("GainX 2000 coupé") != nil })
}

// Symbole éteint (pause à plat, coupe) en marche : l'attente démarre seule
// et propose le 🟢 ; /annuler l'arrête jusqu'à ce que tout retourne.
func TestAutoWatch(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, ruled("interdit", "autorise", "MAX GainX 2000"))
	f.bot.tickWatches(context.Background())
	if _, ok := f.bot.watching(account); !ok {
		t.Fatal("attente automatique attendue")
	}
	if _, button := f.keyboard(t, "Go-to-market</b>"); button != "▶️ Démarrer PainX 2000" {
		t.Fatalf("PainX 2000 au 🟢 doit être proposé : %s", button)
	}
	f.say(t, me, "/annuler")
	f.bot.tickWatches(context.Background())
	if _, ok := f.bot.watching(account); ok {
		t.Fatal("/annuler : pas d'attente automatique")
	}
	f.setStatus(t, ruled("interdit", "autorise", "MAX GainX 2000", "MAX PainX 2000"))
	f.bot.tickWatches(context.Background())
	f.setStatus(t, ruled("interdit", "autorise", "MAX GainX 2000"))
	f.bot.tickWatches(context.Background())
	if _, ok := f.bot.watching(account); !ok {
		t.Fatal("après que tout a tourné, l'attente automatique reprend")
	}
}

// /go en mode par symbole : seuls les 🟢, sinon rien.
func TestGoPerSymbol(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, ruled("interdit", "interdit"))
	f.say(t, me, "/go")
	if f.fake.said("Rien à démarrer maintenant") == nil {
		t.Fatal("tout au 🔴 : rien à démarrer")
	}
	f.setStatus(t, ruled("interdit", "autorise"))
	f.say(t, me, "/go")
	if _, button := f.keyboard(t, "Go-to-market</b>"); button != "▶️ Démarrer PainX 2000" {
		t.Fatalf("/go doit proposer les 🟢 : %s", button)
	}
}

func TestRobotStatusManualDecision(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, manual)
	f.say(t, me, "/etat")
	if f.fake.said("(tu décides à -440, arrêt automatique à -880)") == nil {
		t.Fatal("/etat doit dire qui décide à -440")
	}
}

// Watchdog 1.33 : l'Actus, /etat et les verdicts parlent sur 1 h ; la
// contre-tendance confirmée est dite en clair.
func TestOneHourTrendAndCounter(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, func(s map[string]any) {
		ruled("interdit", "autorise", "MAX GainX 2000", "MAX PainX 2000")(s)
		m := s["market"].([]map[string]any)
		m[0]["trend_1h"], m[0]["chg_60m_pct"], m[0]["counter"] = "baisse", -0.42, true
		m[1]["trend_1h"], m[1]["chg_60m_pct"] = "neutre", 0.05
	})
	text, _ := f.bot.actusText(account, f.bot.now())
	for _, want := range []string{
		"<b>GainX 2000</b> baisse nettement (-0,4 % en 1 h, -3,0 % sur 24 h).",
		"<b>PainX 2000</b> reste stable (+0,1 % en 1 h, -6,0 % sur 24 h).",
		"Contre-tendance confirmée : M5, et M30 ou H1, vont contre le robot.",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("actus sans %q :\n%s", want, text)
		}
	}
	if strings.Contains(text, "en 4 h") {
		t.Fatalf("plus de 4 h quand le Watchdog donne 1 h :\n%s", text)
	}
	f.say(t, me, "/etat")
	if f.fake.said("<b>GainX 2000</b> baisse nettement (-0,4 % en 1 h)") == nil {
		t.Fatal("/etat doit parler sur 1 h")
	}
}

// buttonNamed renvoie le callback_data du bouton text du dernier message contenant want.
func (f *fixture) buttonNamed(t *testing.T, want, text string) string {
	t.Helper()
	body := f.fake.said(want)
	if body == nil {
		t.Fatalf("pas de message %q", want)
	}
	b, _ := json.Marshal(body["reply_markup"])
	var kb struct {
		Rows [][]struct {
			Text string `json:"text"`
			Data string `json:"callback_data"`
		} `json:"inline_keyboard"`
	}
	json.Unmarshal(b, &kb)
	for _, row := range kb.Rows {
		for _, btn := range row {
			if btn.Text == text {
				return btn.Data
			}
		}
	}
	t.Fatalf("message %q sans bouton %q : %s", want, text, b)
	return ""
}

// moded : ruled, avec la règle choisie de chaque symbole (Watchdog 1.34).
func moded(ruleGainX, rulePainX, modeGainX, modePainX string, goGainX, goPainX bool, open ...string) func(s map[string]any) {
	return func(s map[string]any) {
		ruled(ruleGainX, rulePainX, open...)(s)
		m := s["market"].([]map[string]any)
		m[0]["rule_mode"], m[0]["allowed"], m[0]["jump_age_min"], m[0]["jump_late"] = modeGainX, goGainX, 5, false
		m[1]["rule_mode"], m[1]["allowed"], m[1]["jump_age_min"], m[1]["jump_late"] = modePainX, goPainX, 47, !goPainX
	}
}

// Règle choisie : /etat la dit en clair, et le go-to-market suit son verdict,
// pas celui de la tendance.
func TestChosenRuleDrivesGoToMarket(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, moded("interdit", "autorise", "none", "jump", true, false))
	f.say(t, me, "/etat")
	body := f.fake.said("Sans règle")
	if body == nil || !strings.Contains(body["text"].(string), "règle saut &#183; dernier saut il y a 47 min") ||
		!strings.Contains(body["text"].(string), "Pas de saut depuis trop longtemps") {
		t.Fatalf("/etat doit dire la règle choisie : %v", body)
	}
	f.say(t, me, "/go")
	if _, button := f.keyboard(t, "Go-to-market</b>"); button != "▶️ Démarrer GainX 2000" {
		t.Fatalf("sans règle, GainX 2000 démarre ; PainX 2000 attend son saut : %s", button)
	}
}

// /regles : un bouton par symbole, puis les 4 règles ; le choix écrit rules.flag.
func TestRulesCommandAndChoice(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, moded("interdit", "autorise", "trend", "trend", false, true))
	f.say(t, me, "/regles")
	f.press(t, f.buttonNamed(t, "Règle par symbole", "Changer GainX 2000"))
	f.press(t, f.buttonNamed(t, "Quelle règle pour GainX 2000", "Saut"))
	waitFor(t, "rules.flag absent", func() bool { return f.exists(contract.RulesFlag) })
	if f.exists(contract.KillFlag) {
		t.Fatal("un choix de règle ne doit jamais tout arrêter")
	}
	raw, _ := os.ReadFile(filepath.Join(f.dir, contract.RulesFlag))
	var rr contract.RulesRequest
	json.Unmarshal(raw, &rr)
	if rr.Symbol != "MAX GainX 2000" || rr.Mode != "jump" {
		t.Fatalf("rules.flag inattendu : %s", raw)
	}
	f.answer(t, 1, contract.RulesFlag, "rule_mode", "RÈGLE DE GainX 2000 : saut (depuis Telegram, avant : tendance)")
	waitFor(t, "pas de confirmation", func() bool { return f.fake.said("GainX 2000 suit maintenant la règle saut") != nil })
}

// playLecteur joue le Lecteur : prend compare.flag et écrit lecteur.json.
func (f *fixture) playLecteur(t *testing.T, best map[string]string) contract.CompareRequest {
	t.Helper()
	waitFor(t, "compare.flag absent", func() bool { return f.exists(contract.CompareFlag) })
	raw, _ := os.ReadFile(filepath.Join(f.dir, contract.CompareFlag))
	os.Remove(filepath.Join(f.dir, contract.CompareFlag))
	var req contract.CompareRequest
	json.Unmarshal(raw, &req)
	tally := func(n int, total float64) contract.LecteurTally {
		return contract.LecteurTally{N: n, Wins: n / 2, Total: total}
	}
	l := contract.Lecteur{V: 1, Version: "1.0", RequestID: &req.RequestID, TS: time.Now().UTC(), Account: account,
		Days: req.Days, JumpLateMin: req.JumpLateMin}
	for _, s := range req.Symbols {
		ls := contract.LecteurSymbol{Symbol: s, Want: "buy", Lot: 0.2, Best: best[s], BestBy: "market",
			Market: map[string]contract.LecteurTally{"trend": tally(100, 50), "jump": tally(300, -20), "both": tally(90, 60), "none": tally(400, -300)},
			Robot:  map[string]contract.LecteurTally{"trend": {}, "jump": {}, "both": {}, "none": {}}}
		l.Symbols = append(l.Symbols, ls)
	}
	b, _ := json.Marshal(l)
	os.WriteFile(filepath.Join(f.dir, contract.LecteurFile), b, 0o644)
	return req
}

func fastLecteur(t *testing.T, wait time.Duration) {
	poll, w := lecteurPoll, lecteurWait
	lecteurPoll, lecteurWait = 20*time.Millisecond, wait
	t.Cleanup(func() { lecteurPoll, lecteurWait = poll, w })
}

// /comparatif : la demande au Lecteur, puis le comparatif avec un bouton par
// symbole dont la meilleure règle n'est pas la sienne.
func TestComparatifRecommends(t *testing.T) {
	fastLecteur(t, 5*time.Second)
	f := newFixture(t)
	f.setStatus(t, moded("interdit", "autorise", "trend", "both", false, true))
	f.say(t, me, "/comparatif")
	if f.fake.said("Comparatif demandé") == nil {
		t.Fatal("la demande doit être annoncée")
	}
	req := f.playLecteur(t, map[string]string{"MAX GainX 2000": "none", "MAX PainX 2000": "both"})
	if req.Days != 30 || req.JumpLateMin != 40 || len(req.Symbols) != 2 {
		t.Fatalf("compare.flag inattendu : %+v", req)
	}
	waitFor(t, "pas de comparatif", func() bool { return f.fake.said("Comparatif des règles") != nil })
	text := f.fake.said("Comparatif des règles")["text"].(string)
	for _, want := range []string{
		"<b>GainX 2000</b> &#183; ta règle : tendance &#183; lot 0,2",
		"&#x2022; <b>aucune</b> : marché <b>-300</b>, allumé 100 %",
		"&#x2022; tendance : marché +50, allumé 25 %",
		"Meilleure ici : <b>tendance et saut</b> (d'après le marché) : c'est déjà ta règle.",
		"Vrais trades : aucun cycle du robot sur la période.",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("comparatif sans %q :\n%s", want, text)
		}
	}
	f.press(t, f.buttonNamed(t, "Comparatif des règles", "✅ GainX 2000 : règle aucune"))
	waitFor(t, "rules.flag absent", func() bool { return f.exists(contract.RulesFlag) })
	raw, _ := os.ReadFile(filepath.Join(f.dir, contract.RulesFlag))
	var rr contract.RulesRequest
	json.Unmarshal(raw, &rr)
	if rr.Symbol != "MAX GainX 2000" || rr.Mode != "none" {
		t.Fatalf("rules.flag inattendu : %s", raw)
	}
}

// Sans Lecteur dans MT5 : la marche à suivre pour l'ajouter.
func TestComparatifWithoutLecteur(t *testing.T) {
	fastLecteur(t, 200*time.Millisecond)
	f := newFixture(t)
	f.setStatus(t, moded("interdit", "autorise", "trend", "trend", false, true))
	f.say(t, me, "/comparatif")
	waitFor(t, "pas d'aide", func() bool { return f.fake.said("Le Lecteur n'a pas répondu") != nil })
	if !strings.Contains(f.fake.said("Le Lecteur n'a pas répondu")["text"].(string), "<b>Ajouter un service</b>") {
		t.Fatal("la marche à suivre doit être donnée")
	}
}

func TestNextComparatif(t *testing.T) {
	at := func(s string) time.Time { v, _ := time.Parse(time.RFC3339, s); return v }
	if got := nextComparatif(at("2026-09-25T20:00:00Z")); !got.Equal(at("2026-09-25T21:05:00Z")) {
		t.Fatalf("avant 21:05 : %v", got)
	}
	if got := nextComparatif(at("2026-09-25T21:05:00Z")); !got.Equal(at("2026-09-26T21:05:00Z")) {
		t.Fatalf("à 21:05 : %v", got)
	}
}
