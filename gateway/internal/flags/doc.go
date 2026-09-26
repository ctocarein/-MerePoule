// Package flags : écrit les demandes kill, pause, relaunch, reset et config
// dans le dossier du compte, de façon atomique (fichier temporaire puis
// renommage). Seul le Watchdog les supprime.
package flags
