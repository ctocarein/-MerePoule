package readiness

import (
	"fmt"
	"strings"
	"time"
)

// Niveaux d'un point de contrôle.
const (
	OK      = "ok"
	Warning = "warning" // à surveiller, la machine tient quand même
	Error   = "error"   // la machine ne tiendra pas 24 h sans correction
)

// TaskName est le nom de la tâche planifiée qui lance la passerelle.
const TaskName = "MerePoule Gateway"

// Check : un point du diagnostic, en langage simple. Detail dit ce qui se
// passe et ce que ça change pour la surveillance ; Fix, quoi faire, en clics ;
// Tech, la commande équivalente pour les initiés.
type Check struct {
	ID     string `json:"id"`
	Label  string `json:"label"`
	Level  string `json:"level"`
	Detail string `json:"detail"`
	Fix    string `json:"fix,omitempty"`
	Tech   string `json:"tech,omitempty"`
}

type Report struct {
	CheckedAt time.Time `json:"checked_at"`
	Ready     bool      `json:"ready"` // aucun point en erreur
	Checks    []Check   `json:"checks"`
}

func newReport(checks []Check) Report {
	r := Report{CheckedAt: time.Now().UTC(), Ready: true, Checks: checks}
	for _, c := range checks {
		if c.Level == Error {
			r.Ready = false
		}
	}
	return r
}

// Problems compte les points en erreur et à surveiller.
func (r Report) Problems() (errors, warnings int) {
	for _, c := range r.Checks {
		switch c.Level {
		case Error:
			errors++
		case Warning:
			warnings++
		}
	}
	return
}

// Text : le rapport en texte brut, pour la console et le journal.
func (r Report) Text() string {
	var sb strings.Builder
	mark := map[string]string{OK: "OK   ", Warning: "ATTN ", Error: "ECHEC"}
	for _, c := range r.Checks {
		fmt.Fprintf(&sb, "%s %s : %s\n", mark[c.Level], c.Label, c.Detail)
		if c.Level != OK && c.Fix != "" {
			fmt.Fprintf(&sb, "      -> %s\n", c.Fix)
		}
		if c.Level != OK && c.Tech != "" {
			fmt.Fprintf(&sb, "      -> initiés : %s\n", c.Tech)
		}
	}
	errs, warns := r.Problems()
	if r.Ready && warns == 0 {
		sb.WriteString("Prêt pour le 24 h.\n")
	} else {
		fmt.Fprintf(&sb, "%d point(s) à corriger, %d à surveiller.\n", errs, warns)
	}
	return sb.String()
}

// Fingerprint résume les points à régler (identifiant et niveau), pour ne
// signaler le diagnostic que quand il change.
func (r Report) Fingerprint() string {
	var parts []string
	for _, c := range r.Checks {
		if c.Level != OK {
			parts = append(parts, c.ID+":"+c.Level)
		}
	}
	return strings.Join(parts, ",")
}
