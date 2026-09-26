// Package requests dépose les demandes de l'app (drapeaux) et suit leur
// issue dans le journal du Watchdog : pending, puis executed ou refused
// quand l'événement portant le request_id arrive, timeout sinon.
package requests

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"maps"
	"sync"
	"time"

	"merepoule/gateway/internal/contract"
	"merepoule/gateway/internal/flags"
	"merepoule/gateway/internal/store"
)

type Kind string

const (
	Kill     Kind = "kill"
	Pause    Kind = "pause"
	Relaunch Kind = "relaunch"
	Reset    Kind = "reset"
	Config   Kind = "config"
	Robot    Kind = "robot"
	Cut      Kind = "cut"   // un seul symbole (Watchdog 1.32)
	Rules    Kind = "rules" // règle choisie pour un symbole (Watchdog 1.34)
)

func (k Kind) flag() string {
	switch k {
	case Pause:
		return contract.PauseFlag
	case Relaunch:
		return contract.RelaunchFlag
	case Robot:
		return contract.RobotFlag
	case Reset:
		return contract.ResetFlag
	case Config:
		return contract.ConfigFlag
	case Cut:
		return contract.CutFlag
	case Rules:
		return contract.RulesFlag
	}
	return contract.KillFlag
}

const (
	Pending  = "pending"
	Executed = "executed"
	Refused  = "refused"
	Timeout  = "timeout"
)

// Issue de chaque type d'événement pour la demande qu'il cite. Une demande
// sans effet parce que l'état est déjà celui voulu est exécutée : un second
// STOP n'est pas un échec.
var outcome = map[string]string{
	"kill": Executed, "kill_ignored": Executed,
	"pause": Executed, "pause_ignored": Executed,
	"relaunch": Executed, "relaunch_ignored": Executed,
	"reset": Executed, "config": Executed, "robot_params": Executed,
	"reset_refused": Refused, "reset_ignored": Refused,
	"relaunch_refused": Refused, "config_refused": Refused, "robot_params_refused": Refused,
	"symbol_cut": Executed, "symbol_cut_refused": Refused,
	"rule_mode": Executed, "rule_mode_refused": Refused,
}

// Une demande passée en timeout reste suivie un moment : si le Watchdog
// muet se réveille, son issue réelle remplace le timeout.
const lateWindow = 10 * time.Minute

// ErrBusy : une demande de seuils attend encore le Watchdog.
var ErrBusy = errors.New("une demande du même type attend encore le Watchdog")

type Tracker struct {
	store   *store.Store
	common  string
	timeout time.Duration
	now     func() time.Time

	mu     sync.Mutex
	active map[string]store.Request // pending, ou timeout depuis moins de lateWindow
}

func New(st *store.Store, common string) (*Tracker, error) {
	t := &Tracker{
		store:   st,
		common:  common,
		timeout: contract.RequestTimeout,
		now:     time.Now,
		active:  map[string]store.Request{},
	}
	pending, err := st.PendingRequests()
	if err != nil {
		return nil, err
	}
	for _, r := range pending {
		t.active[r.ID] = r
	}
	return t, nil
}

// Submit dépose la demande. id vide : un UUID est tiré. Une demande de
// même id, ou du même type encore en attente pour ce compte, est renvoyée
// telle quelle avec created = false : le drapeau précédent n'a pas encore
// été lu et le réécrire perdrait son request_id. Pour les seuils et les
// réglages du robot et les règles, une seconde demande pourrait porter
// d'autres valeurs : ErrBusy.
func (t *Tracker) Submit(account int64, kind Kind, id, deviceID, origin string, payload map[string]any) (r store.Request, created bool, err error) {
	t.mu.Lock()
	defer t.mu.Unlock()

	if id != "" {
		if r, ok := t.active[id]; ok {
			return r, false, nil
		}
		if r, err := t.store.Request(id); err == nil {
			return r, false, nil
		}
	}
	for _, r := range t.active {
		if r.Account == account && r.Kind == string(kind) && r.State == Pending {
			if kind == Config || kind == Robot || kind == Rules {
				return r, false, ErrBusy
			}
			return r, false, nil
		}
	}
	if id == "" {
		id = NewID()
	}

	body := maps.Clone(payload)
	if body == nil {
		body = map[string]any{}
	}
	body["request_id"] = id
	body["origin"] = origin
	if err := flags.Write(contract.AccountDirUnder(t.common, account), kind.flag(), body); err != nil {
		return r, false, fmt.Errorf("drapeau %s non déposé : %w", kind, err)
	}

	r = store.Request{ID: id, Account: account, Kind: string(kind), DeviceID: deviceID,
		CreatedAt: t.now().UTC(), State: Pending}
	t.active[id] = r
	return r, true, t.store.SaveRequest(r)
}

// OnEvent résout la demande citée par un événement du journal.
func (t *Tracker) OnEvent(account int64, e contract.Event) {
	if e.RequestID == nil {
		return
	}
	state, ok := outcome[e.Type]
	if !ok {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	r, ok := t.active[*e.RequestID]
	if !ok || r.Account != account {
		return
	}
	now := t.now().UTC()
	r.State, r.ResolvedAt, r.EventSeq, r.Detail = state, &now, e.Seq, e.Message
	delete(t.active, r.ID)
	t.store.SaveRequest(r)
}

// Sweep passe en timeout les demandes restées sans réponse.
func (t *Tracker) Sweep() {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now().UTC()
	for id, r := range t.active {
		switch {
		case r.State == Pending && now.Sub(r.CreatedAt) > t.timeout:
			r.State, r.ResolvedAt = Timeout, &now
			r.Detail = "aucune réponse du Watchdog"
			t.active[id] = r
			t.store.SaveRequest(r)
		case r.State == Timeout && now.Sub(r.CreatedAt) > lateWindow:
			delete(t.active, id)
		}
	}
}

func (t *Tracker) Run(ctx context.Context) {
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			t.Sweep()
		}
	}
}

func (t *Tracker) Get(id string) (store.Request, error) {
	t.mu.Lock()
	r, ok := t.active[id]
	t.mu.Unlock()
	if ok {
		return r, nil
	}
	return t.store.Request(id)
}

// NewID renvoie un UUID v4.
func NewID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// ValidID accepte un UUID fourni par l'app (en-tête Idempotency-Key).
func ValidID(id string) bool {
	if len(id) != 36 {
		return false
	}
	for i, c := range id {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
			continue
		}
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}
