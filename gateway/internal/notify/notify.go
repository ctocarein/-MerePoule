package notify

import (
	"context"
	"fmt"
	"html"
	"strconv"
	"sync"
	"time"

	"merepoule/gateway/internal/watcher"
)

// MuteAfter : silence au-delà duquel un Watchdog est signalé muet. Plus long
// que le rechargement d'un EA (quelques secondes), plus court qu'une panne
// qu'on laisserait passer.
const MuteAfter = 90 * time.Second

// Sink reçoit les alertes de la passerelle, en HTML Telegram : le bot
// aujourd'hui, le push Firebase ensuite.
type Sink interface {
	Broadcast(ctx context.Context, html string)
}

// Vigil signale les Watchdogs qui se taisent, puis leur retour. MT5 planté
// ou fermé n'envoie rien lui-même : seule la passerelle peut le voir.
type Vigil struct {
	w     *watcher.Watcher
	sinks []Sink
	now   func() time.Time

	mu    sync.Mutex
	muted map[int64]time.Time // compte -> heure du dernier statut quand l'alerte est partie
}

func NewVigil(w *watcher.Watcher, sinks ...Sink) *Vigil {
	return &Vigil{w: w, sinks: sinks, now: time.Now, muted: map[int64]time.Time{}}
}

func (v *Vigil) Run(ctx context.Context) {
	tick := time.NewTicker(10 * time.Second)
	defer tick.Stop()
	for {
		v.Check(ctx)
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

// Check compare chaque statut à MuteAfter et envoie les alertes de changement.
func (v *Vigil) Check(ctx context.Context) {
	now := v.now()
	for _, account := range v.w.Accounts() {
		snap, _ := v.w.Snapshot(account)
		st := snap.Status
		silent := now.Sub(st.TS)
		who := html.EscapeString(label(account, st.Label))

		v.mu.Lock()
		_, wasMuted := v.muted[account]
		switch {
		case silent > MuteAfter && !wasMuted:
			v.muted[account] = st.TS
			v.mu.Unlock()
			v.send(ctx, fmt.Sprintf("&#x26A0;&#xFE0F; <b>La Mère ne répond plus</b> &#183; %s\n"+
				"Aucune nouvelle depuis %s (dernières à %s GMT).\n"+
				"MT5 fermé ou planté, MerePoule retiré de son graphique, ou session Windows fermée : plus aucune surveillance.\n"+
				"<i>Le filet de sécurité (Bouclier) reste en place chez le courtier.</i>",
				who, Duration(silent), st.TS.UTC().Format("15:04")))
		case silent <= MuteAfter && wasMuted:
			since := v.muted[account]
			delete(v.muted, account)
			v.mu.Unlock()
			v.send(ctx, fmt.Sprintf("&#x2705; <b>La Mère répond de nouveau</b> &#183; %s\nSilence de %s ; la surveillance reprend.",
				who, Duration(st.TS.Sub(since))))
		default:
			v.mu.Unlock()
		}
	}
}

// Muted liste les comptes dont le Watchdog est muet.
func (v *Vigil) Muted() []int64 {
	v.mu.Lock()
	defer v.mu.Unlock()
	out := make([]int64, 0, len(v.muted))
	for a := range v.muted {
		out = append(out, a)
	}
	return out
}

func (v *Vigil) send(ctx context.Context, msg string) {
	for _, s := range v.sinks {
		s.Broadcast(ctx, msg)
	}
}

func label(account int64, l string) string {
	if l == "" {
		return strconv.FormatInt(account, 10)
	}
	return l + " " + strconv.FormatInt(account, 10)
}

// Duration : une durée en clair, « 45 s », « 2 min 30 s », « 1 h 05 min ».
func Duration(d time.Duration) string {
	d = d.Round(time.Second)
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%d s", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%d min %02d s", int(d.Minutes()), int(d.Seconds())%60)
	}
	return fmt.Sprintf("%d h %02d min", int(d.Hours()), int(d.Minutes())%60)
}
