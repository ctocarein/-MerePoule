package notify

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"merepoule/gateway/internal/contract"
	"merepoule/gateway/internal/watcher"
)

type sink struct {
	mu   sync.Mutex
	msgs []string
}

func (s *sink) Broadcast(_ context.Context, html string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.msgs = append(s.msgs, html)
}

func writeStatus(t *testing.T, dir string, ts time.Time) {
	t.Helper()
	b := fmt.Sprintf(`{"v":2,"ts":"%s","account":1,"label":"Démo","state":"RUN"}`, ts.UTC().Format(time.RFC3339))
	if err := os.WriteFile(filepath.Join(dir, contract.StatusFile), []byte(b), 0o644); err != nil {
		t.Fatal(err)
	}
}

// Un Watchdog qui se tait est signalé une fois, puis son retour une fois.
func TestVigil(t *testing.T) {
	common := t.TempDir()
	dir := contract.AccountDirUnder(common, 1)
	os.MkdirAll(dir, 0o755)
	w := watcher.New(common, nil)
	s := &sink{}
	v := NewVigil(w, s)
	ctx := context.Background()

	writeStatus(t, dir, time.Now())
	w.Poll()
	v.Check(ctx)
	if len(s.msgs) != 0 {
		t.Fatalf("aucune alerte attendue pour un Watchdog vivant : %v", s.msgs)
	}

	v.now = func() time.Time { return time.Now().Add(MuteAfter + time.Minute) }
	v.Check(ctx)
	v.Check(ctx)
	if len(s.msgs) != 1 || !strings.Contains(s.msgs[0], "La Mère ne répond plus") || len(v.Muted()) != 1 {
		t.Fatalf("une seule alerte « muet » attendue : %v", s.msgs)
	}

	v.now = time.Now
	writeStatus(t, dir, time.Now())
	w.Poll()
	v.Check(ctx)
	v.Check(ctx)
	if len(s.msgs) != 2 || !strings.Contains(s.msgs[1], "La Mère répond de nouveau") || len(v.Muted()) != 0 {
		t.Fatalf("une seule alerte « de retour » attendue : %v", s.msgs)
	}
}
