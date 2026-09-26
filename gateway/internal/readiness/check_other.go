//go:build !windows

package readiness

// Run : le diagnostic ne concerne que Windows, seule plateforme de MT5.
func Run() Report {
	return newReport([]Check{{ID: "platform", Label: "Système", Level: Warning,
		Detail: "Ce contrôle ne sait vérifier qu'un ordinateur Windows, celui où tourne MT5."}})
}
