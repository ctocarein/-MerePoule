# MerePoule — Watchdog (MQL5)

Expert Advisor posé sur un graphique séparé de ceux du robot. Il lit le
compte chaque seconde, applique les règles de risque, protège les positions
par le Bouclier et exécute l'arrêt lui-même. **Seul composant qui décide
d'un arrêt.** Spécification : sections « Composant 1 » et « Contrat » de
`../docs/MerePoule_Architecture.md`.

| Fichier | Rôle |
| --- | --- |
| `MQL5/Experts/MerePoule/MerePoule.mq5` | L'EA : états RUN, PAUSE, KILL ; boucle, règles, arrêt, seuils à distance, redémarrage |
| `MQL5/Include/MerePoule/Robot.mqh` | Graphiques du robot : trouver, fermer en enregistrant leur modèle, rouvrir, lire et changer leurs réglages |
| `MQL5/Include/MerePoule/Shield.mqh` | Bouclier : stop loss catastrophe côté courtier |
| `MQL5/Include/MerePoule/Market.mqh` | Contexte de marché des symboles du robot (H1) : variation, tendance, agitation |
| `MQL5/Include/MerePoule/Chameleon.mqh` | Caméléon : groupes à contre-tendance avant l'arrêt, en observation, et bilan coupe contre réalité |
| `MQL5/Include/MerePoule/Contract.mqh` | Dossier du compte, fichiers échangés, écriture atomique, journal, drapeaux |
| `MQL5/Include/MerePoule/Json.mqh` | Écriture JSON, lecture des demandes (objets plats) |
| `MQL5/Include/MerePoule/Telegram.mqh` | Alerte directe, indépendante de la passerelle, en HTML (texte brut si Telegram refuse) |
| `MQL5/Include/MerePoule/Text.mqh` | Accents (notation `{e'}`, les sources restent en ASCII), icônes et mise en forme des messages |
| `MQL5/Include/MerePoule/NewsWatch.mqh` | Règle des annonces (calendrier MT5) |
| `MQL5/Include/MerePoule/Jumps.mqh` | Les sauts (bougie M1 à plus de 8 fois le corps médian, dans le sens du robot) et le temps depuis le dernier ; même code pour la Mère et le Lecteur |
| `MQL5/Services/MerePoule/MerePouleLecteur.mq5` | Le Lecteur, service sans graphique, lecture seule : sur `compare.flag`, compare sur 30 jours les règles tendance, saut, les deux et aucune, marché et vrais trades, et écrit `lecteur.json` (décision 30) |
| `MQL5/Scripts/MerePoule/MerePouleRegle.mq5` | Lecture seule : rejoue la règle AUTORISÉ / INTERDIT / RETOURNEMENT sur 30 jours et la confronte aux cycles du robot (bilan dans `MQL5\Files\MerePoule\<compte>\regle.txt`) |
| `MQL5/Scripts/MerePoule/MerePouleCommand.mq5` | Dépose une demande STOP, PAUSE, RELANCER ou RESET, en attendant la passerelle ; aucune commande par défaut |

Version 1.34 : contrat v2 avec pause, relance, Bouclier suiveur et son
alerte de stop loss touché, exposition par symbole, alerte de redémarrage,
réglages du robot, messages accentués et Telegram mis en forme (icône par
événement, titre en gras, heure en pied). La 1.25 ajoute le contexte de
marché (statut et alerte d'arrêt) et, dans l'alerte d'arrêt, la perte par
symbole et par sens et la marche à suivre pour repartir. La 1.26 ajoute le
Caméléon en observation : il annonce le groupe à contre-tendance qu'il
aurait coupé, puis le bilan de ce qu'une coupe aurait donné. La 1.27
lit le sens habituel du robot sur chaque symbole (7 jours d'entrées) :
une tendance ne compte contre lui que si elle va contre ce sens. La 1.28
donne au Caméléon une seconde raison, la perte lourde (−220, toute
tendance), avec un bilan séparé. La 1.29 écrit tous ses messages en
langage simple (décision 23) : « ARRÊT D'URGENCE : la Mère a tout
coupé », « LA MÈRE VEILLE », « filet de sécurité » pour le Bouclier. La 1.30 calcule en direct la règle du trader (M5, M30, H1 ; AUTORISÉ / INTERDIT / retournement), en information seulement, pour l'Actus et l'alerte d'arrêt. La 1.31 sait relancer un seul symbole (go-to-market par symbole) et garde un modèle par graphique. La 1.32 laisse la décision au trader à la perte max (arrêt automatique au dernier filet, 2 fois plus loin), éteint le robot sur un symbole à plat quand la règle est au rouge, et sait couper un seul symbole. La 1.33 met le robot en pause sur un symbole en contre-tendance (positions gardées) et lit le marché sur 1 h. La 1.34 applique la règle choisie pour chaque symbole : tendance, saut (pause quand aucun saut depuis 40 min), les deux ou aucune. La v1.10 a été réécrite d'après le
document d'architecture, faute d'avoir retrouvé sa source d'origine.

## Installation

```powershell
powershell -ExecutionPolicy Bypass -File watchdog\install.ps1
```

Le script copie `MQL5\` dans le dossier de données du terminal Weltrade et
compile ; il échoue sur la moindre erreur. Le terminal peut rester ouvert.
**Un Watchdog déjà posé garde l'ancienne version** : MT5 ne recharge pas un
EA compilé hors de MetaEditor. Le reposer : glisser de nouveau MerePoule
depuis le Navigateur sur son graphique, accepter le remplacement.

Puis, dans MT5 :

1. **Outils > Options > Expert Advisors** : cocher « Autoriser WebRequest »
   et ajouter `https://api.telegram.org`.
2. Ouvrir un graphique **sans robot** (n'importe quel symbole) et y poser
   `MerePoule`, avec « Autoriser le trading algorithmique ».
3. Renseigner `InpLabel` (nom du compte dans l'app), `InpTelegramToken`
   et `InpTelegramChatId`.
4. Vérifier le message `DEMARRAGE` sur Telegram : nombre de graphiques du
   robot trouvés, règles actives, budget du Bouclier, solde d'ouverture du
   jour. S'il annonce « graphique du robot introuvable », il liste les EA
   posés : copier le nom exact dans `InpTargetExperts`.

5. **Le Lecteur, une fois** : dans le Navigateur de MT5, **Services**, clic
   droit, **Ajouter un service**, `MerePouleLecteur`. Il tourne sans
   graphique, redémarre avec MT5, ne trade pas et ne touche pas à la Mère.
   Sans lui, `/comparatif` répond « Le Lecteur n'a pas répondu ». Après une
   nouvelle version : clic droit sur le service, Arrêter, puis Démarrer.

Un Watchdog par compte. Deux comptes sur la même machine, dans deux
terminaux, écrivent chacun dans leur dossier et ne se gênent pas.

Sur un compte démo, le Watchdog agit pour de vrai : une règle déclenchée
ferme les graphiques du robot et toutes les positions surveillées, et **le
Bouclier pose des stop loss sur les positions du robot qui n'en ont pas**,
dès la pose de l'EA.

## Paramètres

| Paramètre | Défaut | Rôle |
| --- | --- | --- |
| `InpLabel` | vide | Nom du compte dans l'app et sur Telegram |
| `InpTargetExperts` | `PETIT POUSSIN 2.V377;RETOUR A LA MAISON PETIT POUSSIN;LE RECUPERATEUR V44.5` | Graphiques fermés à l'arrêt et à la pause, puis à chaque réapparition non autorisée |
| `InpMagicFilter` | 0 | 0 = toutes les positions du compte |
| `InpMarginLevelMin` | 500 | Marge critique, seulement avec des positions ouvertes |
| `InpMarginAction` | alerte seule | Passer en arrêt après calibrage sur démo |
| `InpMaxFloatingLoss` | 440 | Perte flottante, devise du compte |
| `InpMaxDailyDdPct` | 5 | Drawdown journalier, pertes clôturées du jour comprises |
| `InpMaxGivebackPct` | 20 | Recul depuis le plus haut d'equity du jour, à calibrer |
| `InpShield` | oui | Bouclier actif |
| `InpShieldBudget` | 0 | Perte totale si tous ses stop loss sont touchés ; 0 = 2 fois le seuil de perte flottante actif |
| `InpChameleonPct` | 25 | Caméléon, en observation : perte d'un groupe à contre-tendance, en % du seuil de perte flottante actif (−110 pour 440) ; 0 = désactivé. Ne ferme rien |
| `InpManualDecision` | oui | À la perte flottante max, alerte de décision au lieu de l'arrêt ; non = arrêt automatique comme avant |
| `InpFloatingLastResort` | 0 | Arrêt automatique, dernier filet ; 0 = 2 fois la perte flottante max (880) |
| `InpPauseCounter` | oui | Contre-tendance confirmée (M5, et M30 ou H1, contre le robot) : robot en pause sur ce symbole, positions gardées (règle tendance ou les deux) |
| `InpJumpLateMin` | 40 | Règle saut : robot en pause sur un symbole quand aucun saut n'est venu depuis ces minutes, positions gardées (règle saut ou les deux ; 0 = jamais). La règle de chaque symbole se choisit par `/regles` sur Telegram |
| `InpPauseMisaligned` | oui | Règle au rouge et symbole sans position : robot éteint sur ce symbole |
| `InpChameleonHeavyPct` | 50 | Caméléon, en observation : perte lourde d'un groupe, quelle que soit la tendance, en % du seuil (−220 pour 440) ; 0 = désactivé. Ne ferme rien |
| `InpNewsCurrencies` | vide | Annonces à importance haute, ex. `USD;EUR` ; vide = désactivée |
| `InpNewsBeforeMin` / `InpNewsAfterMin` | 10 / 5 | Fenêtre autour de l'annonce, arrêt seulement avec positions |

Tout seuil à 0 désactive sa règle. La cible par défaut contient aussi
« RETOUR A LA MAISON PETIT POUSSIN » et « LE RECUPERATEUR V44.5 » : ce
sont les EA vus sur la démo le 25/09 (GainX et PainX 1000 et 2000). Un EA
absent de la liste continue de tourner après un STOP ou une PAUSE ; en
retirer un seulement s'il ne doit jamais être coupé.

### Bouclier suiveur

Stop loss côté courtier sur les positions qui n'en ont pas : la seule
protection quand la machine tombe. Les positions sont groupées par symbole
et par sens ; chaque groupe reçoit une part égale du budget, et tous ses
stop loss sont posés au prix où le groupe perdrait sa part **en plus de sa
perte actuelle**. Recalage à chaque ouverture ou fermeture de position et
chaque minute, dans les deux sens : en marche normale, il ne coupe pas une
grille qui s'enfonce, ce sont les règles du Watchdog qui protègent. Si la
machine tombe, les stop loss restent où ils étaient.

Un stop loss posé par le robot n'est jamais touché. `InpShield = false`
retire les stop loss posés par le Bouclier. Quand un de ses stop loss est
touché, le Watchdog envoie l'alerte `shield_hit` avec le résultat par
groupe, y compris pour une fermeture survenue machine éteinte (vue au
redémarrage).

La version 1.21 ne faisait que resserrer : sur la démo, elle a coupé deux
grilles de LE RECUPERATEUR en marche normale (décision 17).

### Réglages du robot modifiables à distance

Le Watchdog lit chaque minute les réglages de chaque graphique du robot
dans son modèle et les publie dans le statut : l'app les affiche tous.
Seuls ceux listés dans `InpRobotParams` se changent à distance :

| Paramètre | Défaut | Rôle |
| --- | --- | --- |
| `InpRobotParams` | `InpParamL1:Lot:0.01:0.5` | `input:libellé:min:max`, séparés par `;` ; vide = aucun réglage modifiable |

`InpParamL1` est le nom réel de l'input « Lot » de LE RECUPERATEUR et de
RETOUR A LA MAISON (le libellé affiché par MT5 n'est pas dans le modèle).
Pour un autre robot, relever le nom exact dans le statut
(`targets[].inputs`) ou dans son modèle.

Un changement n'est accepté qu'en RUN, dans les bornes, sur les
graphiques qui portent ce réglage. Le Watchdog réapplique au graphique son
modèle modifié : l'EA redémarre avec la nouvelle valeur, positions
gardées. Chaque changement part sur Telegram.

**Bornes par défaut : lot de 0,01 à 0,5, à ajuster à chaque compte.**

### Seuils modifiables à distance

La passerelle peut changer les quatre seuils de marge, perte flottante,
drawdown et recul, dans des limites qui ne se règlent **que dans MT5** :

| Paramètre | Défaut | Limite |
| --- | --- | --- |
| `InpRemoteConfig` | oui | Non = toute demande refusée |
| `InpCapMarginLevelMin` | 250 | Plus bas seuil de marge accepté, % |
| `InpCapFloatingLoss` | 880 | Plus large perte flottante acceptée |
| `InpCapDailyDdPct` | 10 | Plus large drawdown journalier accepté, % |
| `InpCapGivebackPct` | 40 | Plus large recul accepté, % |

Un plafond à 0 rend sa règle non modifiable à distance. Aucune règle ne se
désactive à distance. « Alerte seule » sur la marge n'est accepté que si
`InpMarginAction` l'est déjà. Une demande est acceptée ou refusée en
entier, et chaque demande part sur Telegram. Les seuils acceptés
survivent au redémarrage ; modifier les paramètres dans MT5 les efface.

Les plafonds par défaut valent deux fois les seuils par défaut : **à
ajuster à la taille de chaque compte.**

## Commandes sans passerelle

Glisser `Scripts\MerePoule\MerePouleCommand` sur un graphique du terminal
du compte visé :

- `STOP` : arrêt d'urgence, exécuté dans la seconde ;
- `PAUSE` : robot coupé, positions gardées sous les règles et le Bouclier ;
  un robot relancé à la main pendant la pause est refermé ;
- `RELANCER` : rouvre les graphiques du robot enregistrés à la pause ou à
  l'arrêt ; termine la pause ; refusé en KILL ;
- `RESET` : réarmement après un arrêt, refusé tant qu'une position ou un
  ordre reste ouvert. Le robot reste coupé : `RELANCER` ensuite.

Pour tester une demande de seuils sans passerelle, écrire à la main
`config.flag` dans le dossier du compte (exemple : `../contract/examples/config.flag`).

## Fichiers et état

Dans `Terminal\Common\Files\MerePoule\<compte>\`, voir `../contract/` :

- écrits : `status.json` chaque seconde, `events.jsonl` à chaque
  événement (renommé `events.1.jsonl` au-delà de 5 Mo) ;
- lus puis supprimés : `kill.flag`, `pause.flag`, `relaunch.flag`,
  `robot.flag`, `reset.flag`, `config.flag`.

Propres au Watchdog, hors contrat :

- modèles des graphiques du robot : `MQL5\Profiles\Templates\MerePoule_<compte>_<n>.tpl` ;
- liste des graphiques à rouvrir : `MQL5\Files\MerePoule\<compte>\robot.txt` ;
- lecture et modification des réglages : `MQL5\Files\MerePoule\<compte>\read.tpl` et `edit_<n>.tpl`.

L'état RUN, PAUSE ou KILL, le solde d'ouverture du jour, le plus haut
d'equity, le numéro du dernier événement, les seuils à distance et les
stop loss posés par le Bouclier vivent dans des variables globales du
terminal (`F3`), préfixées `MerePoule.<compte>.` : ni le retrait de l'EA ni
un redémarrage de MT5 ne réarment le trading.

## Recette

Phase 0 : chaque règle déclenchée volontairement au moins une fois sur
démo, compte à plat à chaque fois. Après chaque arrêt, vérifier le bilan
Telegram, les graphiques du robot fermés et zéro position, puis réarmer
avec `RESET`.

| Test | Comment le provoquer |
| --- | --- |
| Drapeau kill | Script `STOP` |
| Idempotence | Script `STOP` une seconde fois en KILL : `kill_ignored`, rien ne change |
| Perte flottante | `InpMaxFloatingLoss` juste au-dessus de la perte flottante actuelle |
| Drawdown journalier | `InpMaxDailyDdPct` = 0.01 quand l'equity est sous le solde d'ouverture |
| Recul depuis le plus haut | `InpMaxGivebackPct` = 0.01, puis attendre une baisse |
| Marge en arrêt | `InpMarginAction` = arrêt, `InpMarginLevelMin` au-dessus de la marge actuelle |
| Annonce | `InpNewsCurrencies` = `USD`, `InpNewsBeforeMin` = 1440, avec une position ouverte |
| Réapparition | En KILL, relancer le robot : graphique refermé, positions refermées |
| Redémarrage | En KILL, fermer puis rouvrir MT5 : message `ETAT KILL CONSERVE` |
| Réarmement refusé | `RESET` avec une position ouverte à la main : refus |
| Retrait | Retirer l'EA : message `RETRAIT` |

Phase 1 : contrat v2.

| Test | Attendu |
| --- | --- |
| Statut | `merepoule-gateway diag` dans `gateway/` : « Watchdog 1.34 vivant » pour chaque compte |
| Journal | Chaque test ci-dessus ajoute sa ligne à `events.jsonl`, `seq` sans trou |
| `request_id` | Le `request_id` imprimé par le script se retrouve dans l'événement qui répond |
| Seuil accepté | `config.flag` avec `max_floating_loss` sous le plafond : événement `config`, `source` à `remote` dans le statut |
| Seuil refusé | `max_floating_loss` au-dessus du plafond, ou à 0 : `config_refused`, seuils inchangés |
| Retour au local | Modifier un paramètre dans MT5 : `config_cleared`, `source` à `local` |
| Pause | Script `PAUSE` : graphiques du robot fermés, positions toujours ouvertes, état PAUSE |
| Relance après pause | Script `RELANCER` : graphiques rouverts, **robot actif avec ses réglages**, état RUN |
| Relance après arrêt | `STOP`, `RESET`, puis `RELANCER` : le robot repart |
| Relance par Telegram | En KILL, `/relancer` : arrêt, solde et marché affichés ; « Réarmer et attendre le marché » : `reset` dans le journal, robot éteint ; go-to-market puis « Démarrer le robot » : `relaunch`, robot reparti |
| Marché | `market` du statut : une entrée par symbole du robot ; l'alerte d'arrêt donne la perte par symbole et le marché |
| Caméléon | Groupe à contre-tendance sous −110 : message « CAMÉLÉON (observation) », rien de fermé ; à la fermeture du groupe, « CAMÉLÉON (bilan) » avec coupe, réel et cumul |
| Robot rouvert en pause | En PAUSE, reposer le robot à la main : graphique refermé, alerte |
| Réglages lus | `targets[].inputs` du statut : `InpParamL1` de chaque graphique du robot |
| Réglage changé | `essai-reel.ps1 -Robot` : même valeur réécrite, événement `robot_params`, le robot redémarre (`INIT OK` dans son journal) |
| Réglage refusé | Valeur hors bornes : 422 par la passerelle, jamais transmise |
| Bouclier | Positions du robot sans stop loss : événement `shield`, stop loss visibles dans MT5, `shield.unprotected` à 0 |
| Bouclier suiveur | Une grille qui s'enfonce : ses stop loss reculent avec le prix chaque minute, jamais touchés en marche normale |
| Bouclier désactivé | `InpShield = false` : événement `shield` avec `removed`, plus aucun stop loss du Bouclier dans MT5 |
| Stop loss du Bouclier touché | Alerte `shield_hit` sur Telegram avec le résultat du groupe |
| Bouclier, SL du robot | Position avec un stop loss posé par le robot : jamais modifiée |
| Machine redémarrée | Redémarrer Windows : alerte `MACHINE REDEMARREE` avec la durée d'arrêt |
| Deux comptes | Deux terminaux, deux Watchdogs : deux dossiers, deux lignes au diagnostic |

La relance repose sur `ChartApplyTemplate`, qui recharge l'EA du modèle :
vérifier que le robot relancé a bien « Algo Trading » actif et les mêmes
paramètres qu'avant.
