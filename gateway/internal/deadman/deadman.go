package deadman

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Every : rythme des signaux ; le contrôle Healthchecks se règle sur une
// période d'une minute et une tolérance de une à deux minutes.
const Every = time.Minute

// Health dit si tout va bien, et sinon pourquoi, en une ligne.
type Health func() (ok bool, detail string)

// Pinger envoie chaque minute un signal de vie à un service de type « dead
// man's switch » (Healthchecks.io ou équivalent). Si les signaux cessent,
// machine éteinte ou Internet coupé, c'est ce service qui alerte. Quand un
// Watchdog est muet, le signal part sur l'adresse /fail : le service alerte
// aussi, par un canal indépendant de la machine.
type Pinger struct {
	url    string
	health Health
	client *http.Client
}

func New(pingURL string, health Health) *Pinger {
	return &Pinger{url: strings.TrimRight(pingURL, "/"), health: health, client: &http.Client{Timeout: 15 * time.Second}}
}

func (p *Pinger) Run(ctx context.Context) {
	tick := time.NewTicker(Every)
	defer tick.Stop()
	for {
		if err := p.Ping(ctx); err != nil {
			log.Printf("deadman : %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

// Ping envoie un signal : l'adresse telle quelle si tout va bien, /fail sinon,
// avec le détail dans le corps (journal du contrôle chez le service).
func (p *Pinger) Ping(ctx context.Context) error {
	ok, detail := p.health()
	target := p.url
	if !ok {
		target += "/fail"
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target, strings.NewReader(detail))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "text/plain; charset=utf-8")
	res, err := p.client.Do(req)
	if err != nil {
		if ue, ok := err.(*url.Error); ok { // l'URL est un secret : ne garder que la cause
			return ue.Err
		}
		return err
	}
	res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return fmt.Errorf("réponse %d du service de surveillance", res.StatusCode)
	}
	return nil
}
