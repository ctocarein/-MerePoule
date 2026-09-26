// Package deadman : signal de vie sortant, chaque minute, vers un service
// externe de type « dead man's switch » (Healthchecks.io). Seul composant
// qui alerte quand la machine de trading elle-même est éteinte ou coupée
// d'Internet. Un Watchdog muet envoie le signal en échec (/fail).
package deadman
