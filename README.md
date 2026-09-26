# MerePoule

Surveillance et arrêt d'urgence du robot PETIT POUSSIN sur MT5. Trois
composants : le Watchdog sur MT5, une passerelle API sur la machine de
trading, une app mobile. **Seul le Watchdog décide d'un arrêt.** La
passerelle et l'app sont une télécommande et une fenêtre : si elles
tombent, la protection automatique continue. Quand la machine elle-même
tombe, le Bouclier (stop loss catastrophe côté courtier) prend le relais.

L'architecture complète (machine de trading, règles de risque, Bouclier,
contrat de fichiers, endpoints, app, relais cloud, sécurité, scénarios de
défaillance) est dans `docs/MerePoule_Architecture.md`.

## État

| Phase | Statut | Livrable |
| --- | --- | --- |
| 0. Watchdog sur démo | Code livré, compilé ; recette à faire | `watchdog/` : EA, script de commande, `install.ps1` |
| 1. Contrat v2 dans le Watchdog | Code livré (v1.34) ; lecture, PAUSE, RELANCER, réglage du robot, Telegram et arrêt automatique vérifiés sur démo | Dossier par compte, statut, journal, `request_id`, seuils à distance, PAUSE et RELANCER, Bouclier, exposition par symbole, contexte de marché, Caméléon en observation, alerte de redémarrage ; exemples testés dans `contract/` |
| 2. Passerelle Go | En service sur la machine (tâche à l'ouverture de session), `/kill`, `/relancer` avec attente du marché et go-to-market, `/etat` Telegram, diagnostic 24 h ; Tailscale et push à brancher | `gateway/` : API complète, suivi des demandes, jetons et PIN, historique, SQLite, bot Telegram |
| 3. App Flutter | Squelette, analyse sans erreur | `app/` : les huit écrans de l'architecture, vides |
| 4. Passage en réel | Bloqué | Porte phase 3 ; VPS recommandé, PC 24 h accepté avec onduleur, Internet de secours et Bouclier |

## Arborescence

```
docs/        architecture technique et présentation
contract/    exemples des fichiers échangés entre Watchdog et passerelle
watchdog/    Expert Advisor MQL5
gateway/     passerelle API Go (service Windows, Tailscale)
app/         app mobile Flutter (Android, iOS)
```

Chaque composant a son README : installation, lancement, fichiers.

Ce qui reste à faire, et qui le fait : `TACHES.md`.

## Décisions

Détail et conséquences dans l'architecture, décisions 8 à 30 :

- Canal de secours : `/kill` sur le bot Telegram, et `/relancer` après un
  arrêt (décision 18).
- Annonces : arrêt seulement avec des positions ouvertes, comme avant.
- Seuils : modifiables à distance, dans des plafonds réglés dans MT5.
- Périmètre : deux comptes et deux traders pour commencer.
- Répartition imprévisible : une passerelle par compte Windows qui fait
  tourner MT5, une app qui se connecte à plusieurs passerelles.
- PAUSE : robot coupé, positions gardées ; RELANCER rouvre ses graphiques.
- Bouclier suiveur : budget catastrophe réparti par symbole et par sens,
  2 fois le seuil de perte flottante par défaut, recalé chaque minute sur
  le prix, actif par défaut.
- Réglages du robot : visibles dans l'app, modifiables dans une liste et
  des bornes fixées dans MT5.
- Relance depuis Telegram : `/relancer`, puis un bouton ; la Mère réarme,
  laisse le robot éteint, explique le marché et propose un go-to-market
  quand il est resté favorable 10 min. Le robot ne démarre que sur le
  bouton. Refusée tant que des positions sont ouvertes.
- Contexte de marché : variation, tendance et agitation H1 des symboles du
  robot, dans l'alerte d'arrêt, `/etat` et `/relancer`. Aucune règle
  d'arrêt ne s'en sert.
- Caméléon : avant l'arrêt, repérer le groupe à contre-tendance qui perd
  plus du quart du seuil (−110), ou qui perd lourd (−220) quelle que soit
  la tendance. En observation d'abord, avec un bilan
  coupe contre réalité ; actif seulement si le bilan le justifie.
- L'Actus du marché : toutes les 30 min sur Telegram, la météo du marché
  en mots simples et l'état du robot ; `/actus off` pour la couper.
- Langage simple partout : ce qui se passe, que faire, la technique à part.
- Pré-alerte à −300 : message avec « J'ai vu » ; sans réponse en 2 min, la
  Mère appelle sur Telegram (CallMeBot), puis toutes les 5 min.
- Règle AUTORISÉ / INTERDIT / RETOURNEMENT (M5, M30, H1) : à l'étude,
  d'abord mesurée sur l'historique, puis observée, puis appliquée par le
  Watchdog symbole par symbole.
- Pause d'une heure après chaque arrêt d'urgence avant de pouvoir
  redémarrer le robot.
- Go-to-market par symbole : seuls les symboles 🟢 selon ta règle sont
  proposés au démarrage, un bouton chacun.
- Arrêt décisionnel : à −440 tu décides (alerte, appel), arrêt automatique
  à −880 ; symbole au 🔴 et à plat mis en pause ; retournement : alerte
  avec « Couper ce symbole ».
- Règle au choix par symbole (tendance, saut, les deux, aucune) ; le
  Lecteur compare les 4 sur 30 jours, et tu choisis par un bouton.
- Pause en contre-tendance plutôt que coupe : positions gardées, robot
  rallumé quand la règle repasse au 🟢 ; marché lu sur 1 h.

Reste à trancher : la source des annonces du courtier, le calendrier
économique dans l'app pour le Forex, et le calendrier du mode produit
(relais cloud).
