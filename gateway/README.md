# MerePoule — passerelle API (Go)

Binaire unique, lancé à l'ouverture de session sur la machine de trading
**sous le compte Windows qui fait tourner MT5** (tâche planifiée). Expose l'API `/api/v1`,
traduit les commandes en fichiers drapeaux, suit leur exécution dans le
journal du Watchdog. Sert tous les comptes dont un Watchdog a créé le
dossier sous `Common\Files\MerePoule\`. Spécification : sections
« Composant 2 » et « Endpoints » de `../docs/MerePoule_Architecture.md`.

Une passerelle par compte Windows qui fait tourner MT5, quelle que soit la
répartition des comptes entre machines (architecture, « Déploiement »).

## État (phase 2)

Le cœur local est fait et testé : lecture des Watchdogs, demandes et leur
suivi, API complète avec jetons d'appareil et PIN, historique du solde,
base SQLite. Il écoute **en local seulement** (`127.0.0.1:8787`).

Reste à brancher, chacun demandant un compte ou une clé :

| Module | Il faudra |
| --- | --- |
| Exposition Tailscale (`tsnet`) | Une clé d'authentification Tailscale |
| `notify` (push) | Un projet Firebase et sa clé de service ; la vigie passe déjà par Telegram |
| `deadman` | L'adresse de signal d'un contrôle Healthchecks.io (le code est prêt) |
| QR code d'enrôlement | Rien : aujourd'hui le code s'affiche en texte |

## Commandes

```powershell
go build -o merepoule-gateway.exe ./cmd/merepoule-gateway

.\merepoule-gateway.exe serve                         # API sur 127.0.0.1:8787
.\merepoule-gateway.exe enroll -name "Pixel Richmond" # code à usage unique, 5 min
.\merepoule-gateway.exe enroll -name "Tel Trader 2" -accounts 7654321
.\merepoule-gateway.exe diag                          # chaque Watchdog est-il vivant ?
.\merepoule-gateway.exe ready                         # l'ordinateur peut-il veiller 24 h sur 24 ?
.\merepoule-gateway.exe install -telegram-chats 7805445021   # lancement à l'ouverture de session
.\merepoule-gateway.exe install -telegram-chats 7805445021 -deadman-url https://hc-ping.com/<uuid>
.\merepoule-gateway.exe uninstall
go test ./...
```

Options communes : `-common` (dossier commun de MT5, par défaut celui du
compte Windows courant) et `-data` (base SQLite, par défaut
`%LOCALAPPDATA%\MerePoule\gateway`).

**Enrôler un téléphone** : `enroll` affiche un code `XXXXX-XXXXX`. L'app
l'envoie avec le PIN choisi par le trader (6 à 12 chiffres) :

```http
POST /api/v1/devices
{ "code": "ABCDE-FGH23", "pin": "482913", "push_token": "…" }
```

La réponse porte le jeton d'appareil, à mettre dans `Authorization: Bearer`
pour toutes les autres routes. `-accounts` limite le téléphone à certains
comptes : le second trader ne voit que les siens.

**Canal de secours Telegram** : jeton du bot dans la variable
d'environnement (jamais sur la ligne de commande, visible dans le
gestionnaire des tâches), chats autorisés en option :

```powershell
$env:MEREPOULE_TELEGRAM_TOKEN = "<jeton du bot>"
.\merepoule-gateway.exe serve -telegram-chats 7805445021
.\merepoule-gateway.exe serve -telegram-chats "7805445021:43204264,1234567:7654321"
```

`-telegram-chats` : un chat par trader, avec ses comptes après `:`
(séparés par `+`) ; sans compte, le chat voit tous les comptes de la
passerelle. Un chat inconnu reçoit son identifiant, pour faciliter
l'ajout. Le Watchdog peut utiliser le même bot : il ne fait qu'envoyer.

Commandes du bot, dans le menu « / » de Telegram :

| Commande | Effet |
| --- | --- |
| `/etat` | État, equity, Bouclier et marché de chaque compte |
| `/kill` | Arrêt d'urgence, après le bouton « Confirmer l'arrêt » (60 s) |
| `/relancer` | Après un arrêt : raison, solde, marché et verdict, puis « Réarmer et attendre le marché » (60 s). RESET, robot éteint ; go-to-market proposé quand le marché est resté favorable 10 min (aucune tendance forte contre le sens du robot, aucun symbole agité). Refusé d'avance si des positions sont ouvertes, si le robot tourne, si aucun graphique n'est enregistré ou si la perte du jour est déjà au seuil |
| `/go` | Go-to-market à la demande : marché, verdict, puis « Démarrer le robot » (« Démarrer quand même » si défavorable) |
| `/annuler` | Arrête l'attente du marché ; robot toujours éteint |
| `/appel` | L'appel d'alerte : à −300 de perte en cours, alerte avec « J'ai vu » ; sans réponse en 2 min, appel vocal Telegram (CallMeBot), puis toutes les 5 min. `/appel test` essaie, `/appel off` / `on`, `/appel @nom` ou `/appel +225…` change qui est appelé. Première fois : `/start` à @CallMeBot_txtbot |
| `/actus` | L'Actus du marché tout de suite : météo de chaque symbole en mots simples, état du robot. Publiée d'office à chaque heure pile et demi-heure ; `/actus off` la coupe pour ce chat, `/actus on` la reprend |
| `/regles` | La règle de chaque symbole (tendance, saut, les deux ou aucune) et son verdict ; « Changer » puis la règle voulue : la Mère l'applique (`rules.flag`, Watchdog 1.34) |
| `/comparatif` | Demande au Lecteur (service MT5) ce qu'aurait donné chaque règle sur 30 jours, marché et vrais trades, symbole par symbole ; un bouton par symbole dont la meilleure règle n'est pas la sienne. Publié d'office chaque jour à 21:05 GMT |
| `/pret` | Diagnostic « Prêt pour le 24 h », en langage simple : ce qui se passe, que faire, la commande pour les initiés à part |

Avec plusieurs comptes, ajouter le numéro : `/kill 43204264`. Pas de PIN
sur Telegram : activer la validation en deux étapes du compte Telegram.

**Installation** : `install` copie la passerelle dans
`%LOCALAPPDATA%\MerePoule\gateway\`, y range le jeton Telegram
(`telegram.token`, lu depuis `MEREPOULE_TELEGRAM_TOKEN` au moment de
l'installation) et crée la tâche planifiée « MerePoule Gateway » : lancement
à l'ouverture de session, sans fenêtre (`conhost --headless`), journal dans
`gateway.log`, redéclenchée chaque minute pour repartir si elle s'est
arrêtée. Relancer `install` après chaque nouvelle version.

`ready` : code de sortie 0 si la machine est prête, 2 sinon ; le même
diagnostic tourne au démarrage de la passerelle puis toutes les heures. Il
part sur Telegram quand les points à régler changent, ou une fois par jour
s'ils restent : un redémarrage de la passerelle ne le renvoie pas (dernier
envoi noté dans `readiness.last`). `/pret` le demande depuis Telegram.

`diag` : code de sortie 0 si tous les Watchdogs sont vivants, 1 si le
dossier `MerePoule` est introuvable (mauvais compte Windows, ou aucun
Watchdog 1.20 ou plus posé), 2 si un statut est absent, illisible ou
périmé.

## Modules

Un paquet par module de l'architecture, sous `internal/` :

| Paquet | Rôle | État |
| --- | --- | --- |
| `contract` | Contrat v2 : dossiers, fichiers, délais, types ; testé contre `../contract/examples` | Fait |
| `watcher` | Par compte : statut chaque seconde, journal suivi ligne à ligne (lignes coupées, rotation), comptes découverts seuls | Fait |
| `flags` | Demandes kill, pause, relaunch, robot, reset et config, écriture atomique | Fait |
| `requests` | Suivi des demandes : `pending`, `executed`, `refused`, `timeout` ; un second STOP en attente renvoie le premier | Fait |
| `httpapi` | Toutes les routes, flux SSE du statut compris (module `stream` de l'architecture), réglages du robot ; contrôles d'état (409), plafonds et bornes (422), PIN (403, 429) | Fait, local |
| `auth` | Jetons et codes stockés hachés (SHA-256), PIN par téléphone en Argon2id, 5 échecs par heure | Fait ; identité Tailscale à venir |
| `store` | SQLite : appareils, codes, échecs de PIN, copie du journal, demandes (audit), échantillons | Fait |
| `history` | Solde et equity chaque minute ; courbes 24 h, 7 j, 30 j ; résultats par jour et par semaine ; marqueurs | Fait |
| `readiness` | Diagnostic « Prêt pour le 24 h » : veille, alimentation, Windows Update, connexion automatique, lancement de MT5 et de la passerelle | Fait |
| `telegram` | Canal de secours : `/kill` et `/relancer` avec bouton de confirmation, attente du marché et go-to-market, `/go`, `/annuler`, `/etat` avec le marché, `/actus` (Actus du marché toutes les 30 min), `/appel` (pré-alerte à −300 et appel vocal), `/regles` et `/comparatif` (règle par symbole, décision 30), `/pret`, chats autorisés par compte | Fait |
| `call` | Appel vocal Telegram par CallMeBot, pour la pré-alerte | Fait |
| `notify` | Vigie : « Watchdog muet » après 90 s sans statut, puis « de retour », sur Telegram ; push Firebase à venir | Fait (Telegram) |
| `deadman` | Signal de vie chaque minute, `/fail` quand un Watchdog est muet ou qu'aucun n'est lu | Fait, attend l'adresse |

Dépendances : `modernc.org/sqlite` (SQLite sans CGO) et
`golang.org/x/crypto` (Argon2), en versions compatibles avec Go 1.25. Sans
Go 1.26 installé, lancer les commandes `go` avec `GOTOOLCHAIN=local` pour
éviter tout téléchargement de toolchain.

## Essai avec le Watchdog

Watchdog 1.21 posé sur la démo, puis :

```powershell
.\merepoule-gateway.exe serve
.\merepoule-gateway.exe enroll -name "Essai"
curl.exe -X POST http://127.0.0.1:8787/api/v1/devices -d '{\"code\":\"XXXXX-XXXXX\",\"pin\":\"482913\"}'
curl.exe -H "Authorization: Bearer <jeton>" http://127.0.0.1:8787/api/v1/accounts
curl.exe -X POST -H "Authorization: Bearer <jeton>" http://127.0.0.1:8787/api/v1/accounts/<compte>/pause -d '{}'
curl.exe -H "Authorization: Bearer <jeton>" http://127.0.0.1:8787/api/v1/accounts/<compte>/requests/<request_id>
```

La demande passe à `executed` dans la seconde, avec le message du Watchdog.
