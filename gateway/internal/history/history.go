package history

import (
	"context"
	"log"
	"time"

	"merepoule/gateway/internal/store"
	"merepoule/gateway/internal/watcher"
)

const (
	sampleEvery = time.Minute
	keep        = 40 * 24 * time.Hour // un peu plus que la plus longue période
)

// Period décrit une période de l'écran Solde : sa durée et le pas des courbes.
type Period struct {
	Span   time.Duration
	Bucket time.Duration
}

var Periods = map[string]Period{
	"24h": {24 * time.Hour, time.Minute},
	"7d":  {7 * 24 * time.Hour, 10 * time.Minute},
	"30d": {30 * 24 * time.Hour, time.Hour},
}

// Result est le résultat d'un jour ou d'une semaine (UTC), en solde.
type Result struct {
	Start  time.Time `json:"start"`
	Close  float64   `json:"close"`
	Result float64   `json:"result"`
}

type History struct {
	Period  string         `json:"period"`
	Points  []store.Sample `json:"points"`
	Days    []Result       `json:"days"`
	Weeks   []Result       `json:"weeks"`
	Markers []store.Marker `json:"markers"`
}

// Sample enregistre le solde et l'equity de chaque compte dont le statut
// est frais. Un Watchdog muet ne laisse pas de point : le trou se voit.
func Sample(st *store.Store, w *watcher.Watcher, now time.Time) {
	at := now.UTC().Truncate(sampleEvery)
	for _, account := range w.Accounts() {
		snap, ok := w.Snapshot(account)
		if !ok || snap.Status.Stale(now) {
			continue
		}
		if err := st.AddSample(account, at, snap.Status.Balance, snap.Status.Equity); err != nil {
			log.Printf("history: %v", err)
		}
	}
}

func Run(ctx context.Context, st *store.Store, w *watcher.Watcher) {
	tick := time.NewTicker(sampleEvery)
	defer tick.Stop()
	lastPrune := time.Time{}
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-tick.C:
			Sample(st, w, now)
			if now.Sub(lastPrune) > 24*time.Hour {
				lastPrune = now
				if err := st.Prune(now.Add(-keep)); err != nil {
					log.Printf("history: %v", err)
				}
			}
		}
	}
}

// Build assemble l'écran Solde d'un compte pour une période connue.
func Build(st *store.Store, account int64, name string, now time.Time) (History, error) {
	p := Periods[name]
	from := now.Add(-p.Span)
	h := History{Period: name}
	var err error
	if h.Points, err = st.Samples(account, from, p.Bucket); err != nil {
		return h, err
	}
	if h.Markers, err = st.Markers(account, from); err != nil {
		return h, err
	}
	h.Days = results(h.Points, func(t time.Time) time.Time { return t.Truncate(24 * time.Hour) })
	h.Weeks = results(h.Points, weekStart)
	return h, nil
}

// results groupe les points par tranche. Le résultat d'une tranche est son
// dernier solde moins le dernier solde de la tranche précédente, ou moins
// son premier solde pour la première tranche.
func results(points []store.Sample, start func(time.Time) time.Time) []Result {
	out := []Result{}
	var open float64
	for _, p := range points {
		if s := start(p.TS); len(out) == 0 || !out[len(out)-1].Start.Equal(s) {
			if len(out) == 0 {
				open = p.Balance
			} else {
				open = out[len(out)-1].Close
			}
			out = append(out, Result{Start: s})
		}
		last := &out[len(out)-1]
		last.Close = p.Balance
		last.Result = p.Balance - open
	}
	return out
}

// weekStart renvoie le lundi 00:00 UTC de la semaine de t.
func weekStart(t time.Time) time.Time {
	d := t.UTC().Truncate(24 * time.Hour)
	offset := (int(d.Weekday()) + 6) % 7
	return d.AddDate(0, 0, -offset)
}
