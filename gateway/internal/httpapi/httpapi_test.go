package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"merepoule/gateway/internal/auth"
	"merepoule/gateway/internal/contract"
	"merepoule/gateway/internal/requests"
	"merepoule/gateway/internal/store"
	"merepoule/gateway/internal/watcher"
)

const account = 123456

// fixture : un dossier commun avec un Watchdog simulé (statut de l'exemple du
// contrat, horodaté maintenant), la passerelle complète et un client HTTP.
type fixture struct {
	t      *testing.T
	common string
	dir    string
	st     *store.Store
	w      *watcher.Watcher
	srv    *httptest.Server
	seq    int
}

func newFixture(t *testing.T) *fixture {
	f := &fixture{t: t, common: t.TempDir()}
	f.dir = contract.AccountDirUnder(f.common, account)
	os.MkdirAll(f.dir, 0o755)
	f.writeStatus(nil)

	var err error
	if f.st, err = store.Open(filepath.Join(t.TempDir(), "t.db")); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.st.Close() })
	tr, err := requests.New(f.st, f.common)
	if err != nil {
		t.Fatal(err)
	}
	f.w = watcher.New(f.common, func(a int64, e contract.Event, raw []byte, _ bool) {
		f.st.AddEvent(a, e.Seq, e.TS, e.Type, raw)
		tr.OnEvent(a, e)
	})
	f.w.Poll()
	f.srv = httptest.NewServer(New(f.w, f.st, tr))
	t.Cleanup(f.srv.Close)
	return f
}

// writeStatus écrit le statut de l'exemple du contrat, modifié par change.
func (f *fixture) writeStatus(change func(map[string]any)) {
	b, err := os.ReadFile("../../../contract/examples/status.json")
	if err != nil {
		f.t.Fatal(err)
	}
	var s map[string]any
	json.Unmarshal(b, &s)
	s["ts"] = time.Now().UTC().Format(time.RFC3339)
	if change != nil {
		change(s)
	}
	b, _ = json.Marshal(s)
	os.WriteFile(filepath.Join(f.dir, contract.StatusFile), b, 0o644)
}

// answer simule le Watchdog : une ligne de journal qui cite la demande.
func (f *fixture) answer(typ, requestID string) {
	f.seq++
	line := fmt.Sprintf(`{"v":2,"seq":%d,"ts":"%s","account":%d,"type":%q,"level":"info","message":"m","origin":"app:x","request_id":%q}`+"\n",
		f.seq, time.Now().UTC().Format(time.RFC3339), account, typ, requestID)
	fh, _ := os.OpenFile(filepath.Join(f.dir, contract.EventsFile), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	fh.WriteString(line)
	fh.Close()
	f.w.Poll()
}

func (f *fixture) enroll(name string, accounts []int64) string {
	code := auth.NewEnrollmentCode()
	if err := f.st.CreateEnrollment(auth.Hash(auth.NormalizeCode(code)), name, accounts, time.Now().Add(time.Minute)); err != nil {
		f.t.Fatal(err)
	}
	code2, out := f.call("POST", "/devices", "", map[string]any{"code": code, "pin": "482913"}, nil)
	if code2 != http.StatusCreated {
		f.t.Fatalf("enrôlement : %d %v", code2, out)
	}
	return out["token"].(string)
}

func (f *fixture) call(method, path, token string, body any, header map[string]string) (int, map[string]any) {
	f.t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, f.srv.URL+"/api/v1"+path, rd)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range header {
		req.Header.Set(k, v)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		f.t.Fatal(err)
	}
	defer res.Body.Close()
	out := map[string]any{}
	json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}

func readFlag(t *testing.T, dir, name string) map[string]any {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatalf("%s absent : %v", name, err)
	}
	var m map[string]any
	json.Unmarshal(b, &m)
	return m
}

func TestAccountsAndAccess(t *testing.T) {
	f := newFixture(t)
	if code, _ := f.call("GET", "/accounts", "", nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("sans jeton : %d, attendu 401", code)
	}
	token := f.enroll("Pixel Richmond", nil)

	code, out := f.call("GET", "/accounts", token, nil, nil)
	list := out["accounts"].([]any)
	if code != http.StatusOK || len(list) != 1 || list[0].(map[string]any)["label"] != "Richmond démo" {
		t.Fatalf("comptes : %d %v", code, out)
	}
	code, out = f.call("GET", fmt.Sprintf("/accounts/%d/status", account), token, nil, nil)
	if code != http.StatusOK || out["stale"] != false || out["status"].(map[string]any)["watchdog"] != "1.34" {
		t.Fatalf("statut : %d %v", code, out)
	}

	other := f.enroll("Téléphone de l'autre trader", []int64{999})
	if code, _ := f.call("GET", fmt.Sprintf("/accounts/%d/status", account), other, nil, nil); code != http.StatusForbidden {
		t.Fatalf("compte d'un autre trader : %d, attendu 403", code)
	}
	if code, _ := f.call("GET", "/accounts/42/status", token, nil, nil); code != http.StatusNotFound {
		t.Fatalf("compte inconnu : %d, attendu 404", code)
	}
}

// STOP : drapeau déposé avec le request_id de l'app, puis exécuté quand le
// Watchdog répond dans son journal.
func TestKillRoundTrip(t *testing.T) {
	f := newFixture(t)
	token := f.enroll("Pixel Richmond", nil)
	path := fmt.Sprintf("/accounts/%d", account)

	if code, _ := f.call("POST", path+"/kill", token, map[string]any{}, nil); code != http.StatusBadRequest {
		t.Fatalf("sans confirm : %d, attendu 400", code)
	}
	key := requests.NewID()
	code, out := f.call("POST", path+"/kill", token, map[string]any{"confirm": true, "reason": "test"},
		map[string]string{"Idempotency-Key": key})
	if code != http.StatusAccepted || out["request_id"] != key || out["watchdog_stale"] != false {
		t.Fatalf("STOP : %d %v", code, out)
	}
	flag := readFlag(t, f.dir, contract.KillFlag)
	if flag["request_id"] != key || flag["origin"] != "app:Pixel-Richmond" || flag["reason"] != "test" {
		t.Fatalf("drapeau : %v", flag)
	}

	if code, _ := f.call("POST", path+"/kill", token, map[string]any{"confirm": true}, map[string]string{"Idempotency-Key": key}); code != http.StatusOK {
		t.Fatalf("même Idempotency-Key : %d, attendu 200", code)
	}

	f.answer("kill", key)
	code, out = f.call("GET", path+"/requests/"+key, token, nil, nil)
	if code != http.StatusOK || out["state"] != requests.Executed {
		t.Fatalf("suivi : %d %v", code, out)
	}
	code, out = f.call("GET", path+"/events?since=0", token, nil, nil)
	if code != http.StatusOK || len(out["events"].([]any)) != 1 {
		t.Fatalf("journal : %d %v", code, out)
	}

	f.writeStatus(func(s map[string]any) { s["state"] = "KILL"; s["positions"] = 0; s["pending_orders"] = 0 })
	f.w.Poll()
	code, out = f.call("POST", path+"/kill", token, map[string]any{"confirm": true}, nil)
	if code != http.StatusOK || out["state"] != "KILL" || out["request_id"] != nil {
		t.Fatalf("STOP déjà en KILL : %d %v, attendu 200 sans demande", code, out)
	}
}

// Seuils : plafonds vérifiés avant le PIN, puis PIN, puis drapeau ; 5 PIN
// faux bloquent l'appareil une heure, même avec le bon PIN ensuite.
func TestConfigCapsAndPIN(t *testing.T) {
	f := newFixture(t)
	token := f.enroll("Pixel Richmond", nil)
	path := fmt.Sprintf("/accounts/%d/config", account)

	code, out := f.call("PUT", path, token, map[string]any{"pin": "482913", "max_floating_loss": 2000}, nil)
	if code != http.StatusUnprocessableEntity {
		t.Fatalf("au-delà du plafond : %d %v, attendu 422", code, out)
	}
	if code, _ := f.call("PUT", path, token, map[string]any{"pin": "482913", "max_giveback_pct": 0}, nil); code != http.StatusUnprocessableEntity {
		t.Fatalf("désactivation à distance : %d, attendu 422", code)
	}

	code, out = f.call("PUT", path, token, map[string]any{"pin": "482913", "max_floating_loss": 300}, nil)
	if code != http.StatusAccepted {
		t.Fatalf("seuil valable : %d %v", code, out)
	}
	flag := readFlag(t, f.dir, contract.ConfigFlag)
	if flag["max_floating_loss"] != 300.0 || flag["request_id"] != out["request_id"] || flag["pin"] != nil {
		t.Fatalf("drapeau de seuils : %v (le PIN ne doit jamais y figurer)", flag)
	}

	for i := 1; i <= auth.MaxPINFailures; i++ {
		// Chaque PIN faux coûte un hachage Argon2 : sur une machine chargée, le
		// statut vieillirait au-delà de 5 s et la réponse deviendrait 503.
		f.writeStatus(nil)
		f.w.Poll()
		code, _ := f.call("PUT", path, token, map[string]any{"pin": "000000", "max_floating_loss": 250}, nil)
		want := http.StatusForbidden
		if i == auth.MaxPINFailures {
			want = http.StatusTooManyRequests
		}
		if code != want {
			t.Fatalf("PIN faux n°%d : %d, attendu %d", i, code, want)
		}
	}
	if code, _ := f.call("PUT", path, token, map[string]any{"pin": "482913", "max_floating_loss": 250}, nil); code != http.StatusTooManyRequests {
		t.Fatalf("bon PIN après blocage : %d, attendu 429", code)
	}
}

// Relance refusée moins d'une heure après un arrêt (décision 26).
func TestRelaunchPause(t *testing.T) {
	f := newFixture(t)
	token := f.enroll("Pixel Richmond", nil)
	f.writeStatus(func(s map[string]any) {
		s["target_charts"] = 0
		s["last_kill"] = map[string]any{"at": time.Now().Add(-10 * time.Minute).UTC().Format(time.RFC3339), "reason": "perte", "request_id": nil}
	})
	f.w.Poll()
	code, out := f.call("POST", fmt.Sprintf("/accounts/%d/relaunch", account), token, map[string]any{"pin": "482913"}, nil)
	if code != http.StatusConflict || out["error"] != "pause" {
		t.Fatalf("relance pendant la pause : %d %v, attendu 409 pause", code, out)
	}
	if _, err := os.Stat(filepath.Join(f.dir, contract.RelaunchFlag)); err == nil {
		t.Fatal("aucun drapeau pendant la pause")
	}
}

func TestResetAndRelaunchRules(t *testing.T) {
	f := newFixture(t)
	token := f.enroll("Pixel Richmond", nil)
	path := fmt.Sprintf("/accounts/%d", account)

	if code, _ := f.call("POST", path+"/reset", token, map[string]any{"pin": "482913"}, nil); code != http.StatusConflict {
		t.Fatalf("RESET en RUN : %d, attendu 409", code)
	}
	if code, _ := f.call("POST", path+"/relaunch", token, map[string]any{"pin": "482913"}, nil); code != http.StatusConflict {
		t.Fatalf("RELANCER robot en marche : %d, attendu 409", code)
	}

	f.writeStatus(func(s map[string]any) {
		s["state"] = "PAUSE"
		s["target_charts"] = 0
		s["targets"] = []any{}
	})
	f.w.Poll()
	code, out := f.call("POST", path+"/relaunch", token, map[string]any{"pin": "482913"}, nil)
	if code != http.StatusAccepted {
		t.Fatalf("RELANCER en PAUSE : %d %v", code, out)
	}
	readFlag(t, f.dir, contract.RelaunchFlag)

	f.writeStatus(func(s map[string]any) { s["state"] = "KILL"; s["positions"] = 2 })
	f.w.Poll()
	if code, _ := f.call("POST", path+"/reset", token, map[string]any{"pin": "482913"}, nil); code != http.StatusConflict {
		t.Fatalf("RESET avec positions ouvertes : %d, attendu 409", code)
	}

	f.writeStatus(func(s map[string]any) { s["ts"] = "2026-01-01T00:00:00Z" })
	f.w.Poll()
	code, out = f.call("POST", path+"/kill", token, map[string]any{"confirm": true}, nil)
	if code != http.StatusAccepted || out["watchdog_stale"] != true {
		t.Fatalf("STOP Watchdog muet : %d %v, le drapeau part quand même", code, out)
	}
	if code, _ := f.call("GET", path+"/history?period=7d", token, nil, nil); code != http.StatusOK {
		t.Fatalf("historique : %d", code)
	}
}

// Réglages du robot : liste et bornes fixées dans MT5 (lues dans le statut),
// PIN, puis drapeau ; jamais quand le robot est coupé.
func TestRobotParams(t *testing.T) {
	f := newFixture(t)
	token := f.enroll("Pixel Richmond", nil)
	path := fmt.Sprintf("/accounts/%d/robot/params", account)

	for _, body := range []map[string]any{
		{"pin": "482913", "param": "InpParamL1", "value": 0.8},                             // au-delà du plafond
		{"pin": "482913", "param": "InpAutre", "value": 0.1},                               // hors de la liste
		{"pin": "482913", "param": "InpParamL1"},                                           // sans valeur
		{"pin": "482913", "param": "InpParamL1", "value": 0.3, "symbol": "MAX GainX 1000"}, // pas de robot sur ce symbole
	} {
		if code, out := f.call("PUT", path, token, body, nil); code != http.StatusUnprocessableEntity {
			t.Fatalf("%v : %d %v, attendu 422", body, code, out)
		}
	}

	code, out := f.call("PUT", path, token, map[string]any{"pin": "482913", "param": "InpParamL1", "value": 0.3, "symbol": "MAX PainX 2000"}, nil)
	if code != http.StatusAccepted {
		t.Fatalf("réglage valable : %d %v", code, out)
	}
	id := out["request_id"].(string)
	flag := readFlag(t, f.dir, contract.RobotFlag)
	if flag["param"] != "InpParamL1" || flag["value"] != 0.3 || flag["symbol"] != "MAX PainX 2000" || flag["request_id"] != id || flag["pin"] != nil {
		t.Fatalf("drapeau robot : %v", flag)
	}
	if code, _ := f.call("PUT", path, token, map[string]any{"pin": "482913", "param": "InpParamL1", "value": 0.25}, nil); code != http.StatusConflict {
		t.Fatalf("second réglage en attente : %d, attendu 409", code)
	}
	f.answer("robot_params", id)
	if code, out := f.call("GET", fmt.Sprintf("/accounts/%d/requests/%s", account, id), token, nil, nil); code != http.StatusOK || out["state"] != requests.Executed {
		t.Fatalf("suivi : %d %v", code, out)
	}

	f.writeStatus(func(s map[string]any) { s["state"] = "PAUSE"; s["target_charts"] = 0; s["targets"] = []any{} })
	f.w.Poll()
	if code, _ := f.call("PUT", path, token, map[string]any{"pin": "482913", "param": "InpParamL1", "value": 0.3}, nil); code != http.StatusConflict {
		t.Fatalf("robot coupé : %d, attendu 409", code)
	}
}
