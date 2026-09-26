// Package history : échantillonne solde et equity de chaque compte chaque
// minute (SQLite) et assemble l'écran Solde de l'app : courbes sur 24 h,
// 7 j ou 30 j, résultat par jour et par semaine (UTC), marqueurs d'arrêt,
// pause, relance et réarmement. Les trous marquent un Watchdog muet ou une
// passerelle arrêtée.
package history
