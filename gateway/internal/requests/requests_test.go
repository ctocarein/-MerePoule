package requests

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"merepoule/gateway/internal/contract"
	"merepoule/gateway/internal/store"
)

func setup(t *testing.T) (*Tracker, string, *time.Time) {
	t.Helper()
	common := t.TempDir()
	os.MkdirAll(contract.AccountDirUnder(common, 7), 0o755)
	st, err := store.Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	tr, err := New(st, common)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 25, 10, 0, 0, 0, time.UTC)
	tr.now = func() time.Time { return now }
	return tr, common, &now
}

func event(typ, id string, seq int64) contract.Event {
	return contract.Event{Type: typ, RequestID: &id, Seq: seq, Message: typ}
}

func TestSubmitAndResolve(t *testing.T) {
	tr, common, _ := setup(t)
	r, created, err := tr.Submit(7, Kill, "", "dev1", "app:Pixel", map[string]any{"reason": "test"})
	if err != nil || !created || r.State != Pending {
		t.Fatalf("dépôt : %+v %v %v", r, created, err)
	}

	b, err := os.ReadFile(filepath.Join(contract.AccountDirUnder(common, 7), contract.KillFlag))
	if err != nil {
		t.Fatal(err)
	}
	var flag contract.Request
	json.Unmarshal(b, &flag)
	if flag.RequestID != r.ID || flag.Origin != "app:Pixel" || flag.Reason != "test" {
		t.Fatalf("drapeau inattendu : %s", b)
	}

	again, created, _ := tr.Submit(7, Kill, "", "dev2", "app:Autre", nil)
	if created || again.ID != r.ID {
		t.Fatal("un second STOP en attente doit renvoyer la première demande")
	}

	tr.OnEvent(8, event("kill", r.ID, 42)) // autre compte : ignoré
	tr.OnEvent(7, event("kill", r.ID, 42))
	got, _ := tr.Get(r.ID)
	if got.State != Executed || got.EventSeq != 42 {
		t.Fatalf("demande non résolue : %+v", got)
	}
}

func TestRefusedAndBusy(t *testing.T) {
	tr, _, _ := setup(t)
	c1, _, err := tr.Submit(7, Config, "", "dev1", "app:Pixel", map[string]any{"max_floating_loss": 300})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := tr.Submit(7, Config, "", "dev1", "app:Pixel", map[string]any{"max_floating_loss": 200}); err != ErrBusy {
		t.Fatalf("seconde demande de seuils en attente : %v, attendu ErrBusy", err)
	}
	tr.OnEvent(7, event("config_refused", c1.ID, 3))
	if got, _ := tr.Get(c1.ID); got.State != Refused {
		t.Fatalf("attendu refused, obtenu %s", got.State)
	}
}

// Un Watchdog muet fait passer la demande en timeout ; s'il se réveille,
// l'issue réelle remplace le timeout.
func TestTimeoutThenLateAnswer(t *testing.T) {
	tr, _, now := setup(t)
	r, _, _ := tr.Submit(7, Pause, "", "dev1", "app:Pixel", nil)
	*now = now.Add(contract.RequestTimeout + time.Second)
	tr.Sweep()
	if got, _ := tr.Get(r.ID); got.State != Timeout {
		t.Fatalf("attendu timeout, obtenu %s", got.State)
	}
	tr.OnEvent(7, event("pause", r.ID, 9))
	if got, _ := tr.Get(r.ID); got.State != Executed {
		t.Fatalf("réponse tardive ignorée : %s", got.State)
	}
}

func TestIDs(t *testing.T) {
	id := NewID()
	if !ValidID(id) || ValidID("pas-un-uuid") || ValidID(id[:35]+"g") {
		t.Fatal("validation des UUID incorrecte")
	}
}

// Une coupe écrit cut.flag, jamais kill.flag : l'aiguillage par défaut
// mettrait tout le compte à plat.
func TestCutWritesItsOwnFlag(t *testing.T) {
	tr, common, _ := setup(t)
	r, _, err := tr.Submit(7, Cut, "", "telegram:1", "telegram", map[string]any{"symbol": "MAX GainX 2000"})
	if err != nil {
		t.Fatal(err)
	}
	dir := contract.AccountDirUnder(common, 7)
	if _, err := os.Stat(filepath.Join(dir, contract.KillFlag)); err == nil {
		t.Fatal("une coupe ne doit jamais écrire kill.flag")
	}
	b, err := os.ReadFile(filepath.Join(dir, contract.CutFlag))
	if err != nil {
		t.Fatal("cut.flag absent")
	}
	var c contract.CutRequest
	json.Unmarshal(b, &c)
	if c.Symbol != "MAX GainX 2000" || c.RequestID != r.ID {
		t.Fatalf("cut.flag inattendu : %s", b)
	}
	tr.OnEvent(7, event("symbol_cut", r.ID, 1))
	if got, _ := tr.Get(r.ID); got.State != Executed {
		t.Fatalf("symbol_cut doit exécuter la demande : %s", got.State)
	}
}

// Un choix de règle écrit rules.flag, jamais kill.flag ; un second choix
// pendant que le premier attend est refusé : il porterait une autre règle.
func TestRulesWritesItsOwnFlag(t *testing.T) {
	tr, common, _ := setup(t)
	r, _, err := tr.Submit(7, Rules, "", "telegram:1", "telegram", map[string]any{"symbol": "MAX PainX 1000", "mode": "jump"})
	if err != nil {
		t.Fatal(err)
	}
	dir := contract.AccountDirUnder(common, 7)
	if _, err := os.Stat(filepath.Join(dir, contract.KillFlag)); err == nil {
		t.Fatal("un choix de règle ne doit jamais écrire kill.flag")
	}
	b, err := os.ReadFile(filepath.Join(dir, contract.RulesFlag))
	if err != nil {
		t.Fatal("rules.flag absent")
	}
	var rr contract.RulesRequest
	json.Unmarshal(b, &rr)
	if rr.Symbol != "MAX PainX 1000" || rr.Mode != "jump" || rr.RequestID != r.ID {
		t.Fatalf("rules.flag inattendu : %s", b)
	}
	if _, _, err := tr.Submit(7, Rules, "", "telegram:1", "telegram", map[string]any{"symbol": "MAX GainX 1000", "mode": "none"}); err != ErrBusy {
		t.Fatalf("second choix en attente : ErrBusy attendu, %v", err)
	}
	tr.OnEvent(7, event("rule_mode_refused", r.ID, 1))
	if got, _ := tr.Get(r.ID); got.State != Refused {
		t.Fatalf("rule_mode_refused doit refuser la demande : %s", got.State)
	}
}
