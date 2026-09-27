# MerePoule — tâches

Liste vivante de ce qui reste à faire, cochée au fil de l'eau. Le pourquoi
est dans `docs/MerePoule_Architecture.md` ; ici, le quoi et le qui.

**Toi** : dans MT5, sur Windows ou sur ton téléphone. **Moi** : le code, les
essais et la documentation.

## En cours : fin de recette sur la démo

| # | Tâche | Qui | État |
| --- | --- | --- | --- |
| 1 | Reposer MerePoule pour charger la 1.34 (règle au choix par symbole, pause en contre-tendance, marché sur 1 h, décision à −440 et filet à −880), puis vérifier le jeton Telegram dans ses paramètres | Toi | À faire |
| 1b | Ajouter le Lecteur une fois : Navigateur de MT5, Services, clic droit, Ajouter un service, MerePouleLecteur ; puis `/comparatif` sur Telegram | Toi | À faire |
| 1c | Choisir la règle de chaque symbole avec les boutons du comparatif ou `/regles` (décision 30) | Toi | Après 1b |
| 2 | Au prochain arrêt : `/relancer`, attente du marché, puis go-to-market sur Telegram (décision 20) | Toi, moi j'observe | À faire |
| 2c | Règle AUTORISÉ / INTERDIT : premier bilan fait sur 4 jours (non concluant) ; testeur de stratégie sur 3 mois avec LE RECUPERATEUR V44.5 sur les 4 symboles, rapport enregistré en XML, puis je rejoue la règle (décisions 25, 26) | Toi, puis moi | À faire |
| 2b | Appel d'alerte : envoyer /start à @CallMeBot_txtbot, puis /appel test à @MerePouleBot ; le téléphone doit sonner (décision 24) | Toi | À faire |
| 3 | Fermer MT5 3 min : alerte « Watchdog muet », Healthchecks au rouge, puis retour | Toi, moi j'observe | À faire |
| 4 | Seuils à distance : un seuil accepté, un refusé hors plafond, retour au local | Moi, par l'API | À faire |
| 5 | Chaque règle déclenchée une fois : perte flottante, drawdown du jour, recul, marge en arrêt, annonce (détails dans `watchdog/README.md`, Recette) | Toi dans MT5, moi j'observe | À faire |
| 6 | MT5 redémarré en KILL : état conservé, alerte de reprise | Toi | À faire |

Déjà vérifié sur la démo : lecture du compte, PAUSE, RELANCER, réglage du
robot, Bouclier suiveur, STOP par Telegram, alertes Telegram, arrêt
automatique sur perte flottante (25/09 à 07:13, −440,37), relance par
`/relancer` sur Telegram (25/09 à 09:49).

## Machine prête pour le 24 h

`/pret` sur Telegram donne l'état à jour.

| # | Tâche | Qui | État |
| --- | --- | --- | --- |
| 7 | Connexion automatique (outil Autologon de Microsoft) | Toi | À faire |
| 8 | `gpedit.msc` : pas de redémarrage automatique avec des utilisateurs connectés | Toi | À faire |
| 9 | Décocher « Autoriser les importations DLL » si aucun robot n'en a besoin | Toi | À vérifier |
| 10 | Pour l'argent réel : VPS, ou PC avec onduleur et Internet de secours (décision 7) | Toi | Plus tard |

## Phase 2 : passerelle, ce qui reste

| # | Tâche | Qui | État |
| --- | --- | --- | --- |
| 11 | Compte Tailscale, app Tailscale sur ce PC et sur le téléphone, même compte | Toi | À faire |
| 12 | Passerelle joignable par Tailscale, en HTTPS | Moi | Après 11 |
| 13 | Enrôlement par QR code au lieu du code texte | Moi | À faire |

Fait : API, suivi des demandes, jetons et PIN, historique, SQLite, tâche au
démarrage de session, `/kill`, `/relancer` (attente du marché et
go-to-market), `/go`, `/annuler`, `/etat` et l'Actus du marché toutes les
30 min (`/actus`) sur Telegram, diagnostic 24 h, vigie
« Watchdog muet », signal de vie Healthchecks.

## Phase 3 : l'app

| # | Tâche | Qui | État |
| --- | --- | --- | --- |
| 14 | Dire si ton téléphone est un Android ou un iPhone (un iPhone demande un Mac pour compiler) | Toi | À faire |
| 15 | Enrôlement du téléphone, jeton rangé dans le coffre du téléphone | Moi | Après 12 |
| 16 | Comptes et Accueil en direct, bandeau de confiance | Moi | |
| 17 | Bouton rond de l'app : son rôle (plus d'écran Commandes, décidé le 25/09) | Toi | Plus tard |
| 18 | Journal, Solde (courbes), Robot (réglages), Réglages (seuils, téléphones, diagnostic 24 h) | Moi | |
| 19 | Notifications push : projet Firebase (toi), branchement (moi) | Toi et moi | |

Fait : charte graphique et écrans d'après les maquettes (connexion, Accueil,
Solde, Actualités, Journal, bouton rond, menu, cartes à courbe, menu
déroulant des comptes) sur trois comptes de démonstration, icône de l'app,
app en français.
| 20 | Essai complet sur ton téléphone : STOP exécuté et confirmé, push reçus | Toi | Critère de sortie |

## Retrait du dimanche (décision 31)

| # | Tâche | Qui | État |
| --- | --- | --- | --- |
| 29 | Fixer le capital de travail de chaque compte : `/retrait capital 1000` (ton montant) | Toi | À faire |
| 30 | Vérifier dans l'espace client Weltrade les réseaux USDT proposés et la règle « retrait vers le moyen du dépôt » ; même réseau côté Binance | Toi | À faire |
| 31 | Premier retrait réel : noter frais et délai, pour caler le minimum de 10 | Toi | Au réel |

Fait : `/retrait` sur Telegram, point publié chaque dimanche à 18:00 GMT.

## Décisions à prendre

| # | Question | Pour quand |
| --- | --- | --- |
| 21 | Calibrer sur la démo : marge (passer en arrêt ?), recul 20 %, budget du Bouclier, bornes du lot, plafonds des seuils | Avant le réel |
| 22 | Détection de l'empilement : nombre de positions et volume max par symbole (décision 5) | Avant le réel |
| 22b | Caméléon : passer en actif (coupe d'un symbole, puis go-to-market) si le bilan cumulé montre que la coupe épargne ; revoir le seuil de 25 % | Après quelques bilans |
| 23 | Source des annonces du courtier pour l'écran Actualité | Phase 3 |
| 24 | Calendrier économique dans l'app, pour le Forex | Phase 3 |
| 25 | Mode produit (relais cloud) : si et quand | Après la phase 4 |

## Phase 4 : passage en réel

| # | Tâche | Qui |
| --- | --- | --- |
| 26 | Machine 24 h validée (`/pret` au vert) | Toi |
| 27 | Petit capital, seuils serrés | Toi |
| 28 | Revue du journal après chaque arrêt | Toi et moi |
