package watcher

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"

	"merepoule/gateway/internal/contract"
)

// rescanEvery : les nouveaux comptes (un Watchdog posé plus tard) sont
// découverts à ce rythme.
const rescanEvery = 10 * time.Second

// Snapshot est le dernier statut lu pour un compte. Raw est renvoyé tel
// quel à l'app : un champ ajouté par le Watchdog y passe sans attendre la
// passerelle.
type Snapshot struct {
	Status contract.Status
	Raw    json.RawMessage
	ReadAt time.Time
}

// EventFunc reçoit chaque ligne complète du journal, une seule fois.
// backlog est vrai pour les lignes déjà présentes au premier passage : à
// copier, pas à notifier.
type EventFunc func(account int64, e contract.Event, raw []byte, backlog bool)

type Watcher struct {
	common  string
	onEvent EventFunc

	mu    sync.RWMutex
	snaps map[int64]Snapshot

	// Touchés par Poll seul.
	tails    map[int64]*tail
	lastScan time.Time
}

func New(common string, onEvent EventFunc) *Watcher {
	return &Watcher{common: common, onEvent: onEvent, snaps: map[int64]Snapshot{}, tails: map[int64]*tail{}}
}

func (w *Watcher) Run(ctx context.Context) {
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for {
		w.Poll()
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

// Poll fait un passage : découverte des comptes, statut, journal.
func (w *Watcher) Poll() {
	if len(w.tails) == 0 || time.Since(w.lastScan) >= rescanEvery {
		w.lastScan = time.Now()
		accounts, err := contract.AccountsUnder(w.common)
		if err != nil && !errors.Is(err, fs.ErrNotExist) {
			log.Printf("watcher: %v", err)
		}
		for _, a := range accounts {
			if w.tails[a] == nil {
				w.tails[a] = &tail{}
			}
		}
	}

	for account, t := range w.tails {
		dir := contract.AccountDirUnder(w.common, account)
		w.readStatus(account, dir)

		lines, err := t.read(dir)
		if err != nil {
			log.Printf("watcher: journal du compte %d : %v", account, err)
		}
		backlog := !t.started
		t.started = true
		for _, raw := range lines {
			var e contract.Event
			if err := json.Unmarshal(raw, &e); err != nil {
				log.Printf("watcher: ligne illisible du compte %d : %v", account, err)
				continue
			}
			if w.onEvent != nil {
				w.onEvent(account, e, raw, backlog)
			}
		}
	}
}

func (w *Watcher) readStatus(account int64, dir string) {
	raw, err := readShared(filepath.Join(dir, contract.StatusFile))
	if err != nil {
		return // absent ou en cours de remplacement : le dernier connu vieillit et finit périmé
	}
	var s contract.Status
	if err := json.Unmarshal(raw, &s); err != nil {
		return
	}
	w.mu.Lock()
	w.snaps[account] = Snapshot{Status: s, Raw: json.RawMessage(bytes.TrimSpace(raw)), ReadAt: time.Now()}
	w.mu.Unlock()
}

// Accounts liste les comptes dont un statut a été lu, triés.
func (w *Watcher) Accounts() []int64 {
	w.mu.RLock()
	defer w.mu.RUnlock()
	out := make([]int64, 0, len(w.snaps))
	for a := range w.snaps {
		out = append(out, a)
	}
	slices.Sort(out)
	return out
}

func (w *Watcher) Snapshot(account int64) (Snapshot, bool) {
	w.mu.RLock()
	defer w.mu.RUnlock()
	s, ok := w.snaps[account]
	return s, ok
}

// Dir renvoie le dossier du contrat d'un compte.
func (w *Watcher) Dir(account int64) string { return contract.AccountDirUnder(w.common, account) }

// tail suit events.jsonl : seules les lignes terminées par \n sont rendues.
// Le Watchdog renomme le journal en events.1.jsonl au-delà de 5 Mo : la fin
// de l'ancien fichier est lue avant le début du nouveau.
type tail struct {
	file    os.FileInfo
	offset  int64
	partial []byte
	started bool
}

func (t *tail) read(dir string) ([][]byte, error) {
	path := filepath.Join(dir, contract.EventsFile)
	fi, err := os.Stat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	var chunk []byte
	if t.file != nil && (!os.SameFile(t.file, fi) || fi.Size() < t.offset) {
		old, err := readFrom(filepath.Join(dir, contract.EventsOldFile), t.offset)
		if err != nil {
			log.Printf("watcher: fin du journal précédent illisible : %v", err)
		}
		chunk = old
		t.offset = 0
	}
	t.file = fi

	b, err := readFrom(path, t.offset)
	if err != nil {
		return nil, err
	}
	t.offset += int64(len(b))
	chunk = append(chunk, b...)

	data := append(t.partial, chunk...)
	end := bytes.LastIndexByte(data, '\n')
	if end < 0 {
		t.partial = data
		return nil, nil
	}
	t.partial = slices.Clone(data[end+1:])

	var lines [][]byte
	for _, l := range bytes.Split(data[:end], []byte{'\n'}) {
		if l = bytes.TrimSpace(l); len(l) > 0 {
			lines = append(lines, l)
		}
	}
	return lines, nil
}

func readShared(path string) ([]byte, error) { return readFrom(path, 0) }

func readFrom(path string, offset int64) ([]byte, error) {
	f, err := openShared(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		return nil, err
	}
	return io.ReadAll(f)
}
