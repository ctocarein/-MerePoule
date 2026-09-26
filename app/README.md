# MerePoule — app mobile (Flutter)

Télécommande et tableau de bord du trader : elle montre, alerte et transmet
les ordres ; elle ne décide jamais seule. Spécification : section
« Composant 3 » de `../docs/MerePoule_Architecture.md`.

L'app se connecte à une ou plusieurs passerelles (une par QR code) et
regroupe leurs comptes ; un compte est identifié par sa passerelle et son
numéro.

Phase 3 de la feuille de route. Aujourd'hui : les écrans des maquettes, sur
trois **comptes de démonstration** (chiffres d'exemple, `lib/demo/`). Aucune
passerelle n'est encore branchée, aucun ordre ne part.

## Navigation

L'app s'ouvre sur la connexion. « Connexion par Tailscale » mène au premier
compte ; Google et Telegram affichent « arrive bientôt » (mode produit).

En haut, le menu déroulant des comptes : le compte affiché, puis tous les
comptes (avatar, courtier, numéro) et « Ajouter un compte » (bientôt : QR
code de la passerelle). Il remplace l'ancien écran Comptes. Sur un
téléphone, il prend la place du nom MerePoule.

En bas, quatre onglets (Accueil, Solde, Actualités, Journal) et le bouton
rond orange ; en haut à droite, le menu ☰ pour Robot, Réglages et la Charte
graphique (mode développement seulement).

L'Accueil montre quatre cartes à courbe (Solde, Equity, Gain latent, Niveau
de marge) : tendance en %, variation, et menu ⋯ pour choisir la période
(24 h, 7 jours, 30 jours). Deux cartes par ligne sur tablette, une par ligne
sur téléphone, où l'en-tête de chaque carte ne tiendrait pas à deux.

Il n'y a plus d'écran Commandes. Le rôle du bouton rond reste à décider ;
en attendant, il annonce « bientôt ». Le contrôle à distance passe par le bot
Telegram : `/kill` (arrêt d'urgence), `/relancer` (réarmer, robot éteint,
attendre le marché), `/go` (démarrer le robot), `/annuler` (arrêter
l'attente), et pour s'informer `/etat`, `/actus`, `/appel`, `/pret`. Pas de
pause à distance pour l'instant.

## Organisation du code

| Dossier ou fichier | Rôle |
| --- | --- |
| `lib/main.dart` | Démarrage : français, licence de la police |
| `lib/app.dart` | L'app : thèmes, langue, enchaînement connexion → comptes |
| `lib/config.dart` | Réglages fixes : nom, thème, fraîcheur du statut (5 s) |
| `lib/theme/` | Charte graphique, un seul import : `theme/theme.dart` |
| `lib/widgets/` | Briques communes (voir plus bas) |
| `lib/models/` | Ce que l'app affiche : compte, jauges, séries dans le temps, journal, actualités |
| `lib/demo/demo_data.dart` | Les comptes de démonstration ; seront remplacés par les données de la passerelle |
| `lib/utils/format.dart` | Montants, pourcentages, heures et âges à la française |
| `lib/screens/` | Un fichier par écran |
| `assets/fonts/` | Police Noto Sans et sa licence OFL |
| `assets/icon/` | Icône de l'app, source des icônes Android et iOS |
| `tool/make_icon.py` | Dessin de l'icône d'après le logo |

| Écran | Fichier |
| --- | --- |
| Connexion | `lib/screens/login_screen.dart` |
| En-tête et menu des comptes, onglets, bouton rond, menu ☰ | `lib/screens/account_shell.dart` |
| Accueil : état, bandeau de confiance, cartes à courbe, distance au stop-out, jauges | `lib/screens/home_screen.dart` |
| Solde : courbe 24 h, 7 j, 30 j, résultat, plus haut | `lib/screens/balance_screen.dart` |
| Actualités : à la une, filtres, fraîcheur du flux | `lib/screens/news_screen.dart` |
| Journal : événements filtrés, avec leur heure | `lib/screens/journal_screen.dart` |
| Robot, Réglages : « Bientôt » | `robot_screen.dart`, `settings_screen.dart` |
| Charte graphique | `lib/screens/style_guide_screen.dart` |

## Charte graphique

Reprise des maquettes : fond gris très clair, cartes blanches aux coins
arrondis, accent orange, titres et chiffres en gras. Thème clair par défaut
(`lib/config.dart`) ; un thème sombre existe, pas encore proposé.

| Élément | Fichier | Règle |
| --- | --- | --- |
| Couleurs | `lib/theme/palette.dart` | Fond `#F6F7FA`, carte `#FFFFFF`, encre `#101522`, gris `#626D80`, filet `#DFE4EC`, orange `#FF9F1C`, vert `#16C784`, bleu `#0374FE` (marge), rouge `#E5484D`, STOP `#D92D35` |
| Couleurs de sens | `lib/theme/colors.dart` | Chaque signal a une teinte vive (aplat, jauge, grand chiffre) et une teinte foncée pour les petits textes (`okText`, `accentText`…), lisible sur blanc. Toujours avec une icône ou un mot |
| Police | `lib/theme/typography.dart` | Noto Sans, proche de la police des maquettes ; 800 pour les grands chiffres et l'état, 700 pour les titres ; chiffres de largeur fixe (`.figures`) |
| Espacements, arrondis | `lib/theme/spacing.dart` | Grille de 4, marge d'écran 20 ; coins de 14 (boutons, sélecteurs) et 20 (cartes) |
| Icônes | `lib/theme/icons.dart` | Material, contour ; les écrans passent par `MpIcons`, jamais par `Icons` |
| Thèmes | `lib/theme/app_theme.dart` | Boutons, barre d'onglets, bouton rond, menu, champs, réglés une fois |

Briques communes (`lib/widgets/`) : logo, pastille et nom (`brand.dart`),
carte (`mp_card.dart`), carte chiffre (`metric_card.dart`), carte à courbe
(`trend_card.dart`), menu des comptes et avatar (`account_switcher.dart`),
pastilles de tendance (`pill.dart`), pièces (`coins.dart`), sélecteur
(`segmented.dart`), titre d'écran (`page_title.dart`), jauge
(`gauge_bar.dart`), courbes (`line_chart.dart`), bandeau teinté
(`signal_pill.dart`), bandeau de confiance (`trust_banner.dart`), montant
coloré (`amount_text.dart`), pastille d'état (`state_badge.dart`), icône en
rond (`icon_bubble.dart`), écran « Bientôt » (`coming_soon.dart`).

Dans un écran : `import '../theme/theme.dart';`, puis `context.colors`
(couleurs Material), `context.mp` (couleurs de sens), `context.text`
(tailles de texte), `MpSpace`, `MpRadius`, `MpIcons`. Aucune couleur ni
taille écrite en dur dans un écran.

Les tests (`test/theme_test.dart`) vérifient que chaque couleur de petit
texte reste lisible (contraste 4,5 au moins) sur les fonds, en clair et en
sombre.

**Icône** : le logo des maquettes, œuf orange et goutte sombre sur fond
blanc, dessiné par `tool/make_icon.py`. Pour la changer, remplacer
`assets/icon/icon.png` et `assets/icon/icon_foreground.png` (1024 × 1024, le
second sur fond transparent), puis `dart run flutter_launcher_icons`.

## Lancer

Paquets pressentis, à ajouter au fil des écrans : `flutter_riverpod`, `dio`,
un client SSE, `flutter_secure_storage`, `local_auth`, `firebase_messaging`,
`google_sign_in`, `fl_chart` (repères d'arrêt sur la courbe).

L'identifiant d'application `com.merepoule.merepoule` est provisoire : le
fixer avant la première publication sur les stores.

```powershell
flutter pub get
flutter test
flutter run
```

Prérequis sur le téléphone en mode personnel : l'app Tailscale installée et
connectée, sinon les commandes à distance sont impossibles.
