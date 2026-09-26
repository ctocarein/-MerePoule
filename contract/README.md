# Contrat Watchdog ↔ Passerelle, v2

Seule interface entre le Watchdog (MQL5) et la passerelle (Go) : des
fichiers dans le dossier commun de MT5, un sous-dossier par compte,
`%APPDATA%\MetaQuotes\Terminal\Common\Files\MerePoule\<compte>\`. La
référence est la section « Contrat Watchdog ↔ Passerelle » de
`docs/MerePoule_Architecture.md`. Ce dossier en garde les exemples, pour
que les deux côtés testent leur lecture et leur écriture sur les mêmes
fichiers.

| Exemple | Fichier réel | Écrit par |
| --- | --- | --- |
| `examples/status.json` | `status.json` | Watchdog, chaque seconde |
| `examples/events.jsonl` | `events.jsonl` | Watchdog, une ligne par événement |
| `examples/kill.flag` | `kill.flag` | Passerelle |
| `examples/pause.flag` | `pause.flag` | Passerelle |
| `examples/relaunch.flag` | `relaunch.flag` | Passerelle |
| `examples/robot.flag` | `robot.flag` | Passerelle |
| `examples/reset.flag` | `reset.flag` | Passerelle |
| `examples/config.flag` | `config.flag` | Passerelle |

`gateway/internal/contract` lit chaque exemple en refusant tout champ
inconnu (`go test ./...` dans `gateway/`) : un exemple qui s'écarte des
types Go fait échouer le test.

Toute modification du contrat se fait d'abord dans le document
d'architecture, puis ici, puis dans les deux composants.
