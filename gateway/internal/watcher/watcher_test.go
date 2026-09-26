package watcher

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"merepoule/gateway/internal/contract"
)

func line(seq int) string {
	return fmt.Sprintf(`{"v":2,"seq":%d,"ts":"2026-09-25T10:00:00Z","account":1,"type":"alert","level":"warning","message":"m","code":"margin"}`+"\n", seq)
}

func appendTo(t *testing.T, path, s string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.WriteString(s); err != nil {
		t.Fatal(err)
	}
}

// Le journal est lu une ligne complète à la fois, une seule fois, y compris
// quand une ligne est coupée en deux écritures et quand le Watchdog renomme
// le fichier en events.1.jsonl.
func TestTailPartialAndRotation(t *testing.T) {
	common := t.TempDir()
	dir := contract.AccountDirUnder(common, 1)
	os.MkdirAll(dir, 0o755)
	os.WriteFile(filepath.Join(dir, contract.StatusFile),
		[]byte(`{"v":2,"ts":"`+time.Now().UTC().Format(time.RFC3339)+`","account":1,"state":"RUN"}`), 0o644)
	events := filepath.Join(dir, contract.EventsFile)

	var seqs []int64
	var backlogs []bool
	w := New(common, func(account int64, e contract.Event, raw []byte, backlog bool) {
		seqs = append(seqs, e.Seq)
		backlogs = append(backlogs, backlog)
	})

	appendTo(t, events, line(1))
	w.Poll()

	l2 := line(2)
	appendTo(t, events, l2[:20]) // ligne coupée : rien ne doit sortir
	w.Poll()
	if len(seqs) != 1 {
		t.Fatalf("ligne incomplète rendue : %v", seqs)
	}
	appendTo(t, events, l2[20:]+line(3))
	w.Poll()

	appendTo(t, events, line(4)) // pas encore lue au moment de la rotation
	if err := os.Rename(events, filepath.Join(dir, contract.EventsOldFile)); err != nil {
		t.Fatal(err)
	}
	appendTo(t, events, line(5))
	w.Poll()
	w.Poll()

	want := []int64{1, 2, 3, 4, 5}
	if fmt.Sprint(seqs) != fmt.Sprint(want) {
		t.Fatalf("événements %v, attendu %v", seqs, want)
	}
	if !backlogs[0] || backlogs[1] {
		t.Fatalf("seul le premier passage est un arriéré : %v", backlogs)
	}
	if snap, ok := w.Snapshot(1); !ok || snap.Status.State != "RUN" {
		t.Fatal("statut non lu")
	}
}
