import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:merepoule/app.dart';
import 'package:merepoule/screens/style_guide_screen.dart';
import 'package:merepoule/theme/theme.dart';

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(() => initializeDateFormatting('fr_FR'));

  for (final (name, theme) in [
    ('clair', MpTheme.light),
    ('sombre', MpTheme.dark),
  ]) {
    testWidgets('charte graphique en thème $name, sans débordement', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(
        MaterialApp(theme: theme, home: const StyleGuideScreen()),
      );
      // Parcourt toute la page pour construire chaque section.
      await tester.dragUntilVisible(
        find.text('notifications'),
        find.byType(ListView),
        const Offset(0, -300),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('connexion, puis les écrans et les comptes', (tester) async {
    _phone(tester);
    await tester.pumpWidget(const MerePouleApp());

    // Google n'est pas encore branché : un message, pas de navigation.
    await tester.tap(find.text('Continuer avec Google'));
    await tester.pump();
    expect(find.textContaining('arrive bientôt'), findsOneWidget);

    await tester.tap(find.text('Connexion par Tailscale'));
    await tester.pumpAndSettle();
    expect(find.text('Tableau de bord'), findsOneWidget);
    expect(find.text('Compte Démo'), findsOneWidget);
    expect(find.text('RUN'), findsOneWidget);
    expect(find.textContaining('Données à jour'), findsOneWidget);

    // Carte Solde : tendance sur 7 jours, puis 30 jours par son menu ⋯.
    expect(find.text('+21,3 %'), findsOneWidget);
    await tester.tap(find.byTooltip('Période').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 jours').last);
    await tester.pumpAndSettle();
    expect(find.text('+48,0 %'), findsOneWidget);
    expect(find.textContaining('en 30 j'), findsOneWidget);
    // La carte « Le compte tient encore » est plus bas : on fait défiler.
    await tester.dragUntilVisible(
      find.text('Tendance positive'),
      find.byType(ListView).first,
      const Offset(0, -300),
    );
    expect(find.text('Tendance positive'), findsOneWidget);

    await tester.tap(find.text('Solde').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 jours'));
    await tester.pumpAndSettle();
    expect(find.text('Résultat 30 j'), findsOneWidget);

    await tester.tap(find.text('Actualités').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forex'));
    await tester.pumpAndSettle();
    expect(find.text('EUR / USD — marché'), findsOneWidget);
    expect(find.text('Calendrier économique'), findsNothing);

    await tester.tap(find.text('Journal').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Arrêts'));
    await tester.pumpAndSettle();
    expect(find.text('KILL : perte flottante'), findsOneWidget);
    expect(find.text('PAUSE demandée'), findsNothing);

    await tester.tap(find.byTooltip('Menu'));
    await tester.pumpAndSettle();
    expect(find.text('Charte graphique'), findsOneWidget);
    await tester.tap(find.text('Robot'));
    await tester.pumpAndSettle();
    expect(find.text('Bientôt'.toUpperCase()), findsOneWidget);
    // App en français : le bouton retour s'appelle « Retour ».
    await tester.tap(find.byTooltip('Retour'));
    await tester.pumpAndSettle();

    // Plus d'écran Commandes : le bouton rond annonce seulement la suite.
    await tester.tap(find.byTooltip('Bientôt disponible'));
    await tester.pump();
    expect(find.textContaining('pilotez depuis Telegram'), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);

    // Menu déroulant des comptes.
    await tester.tap(find.text('Compte Démo'));
    await tester.pumpAndSettle();
    expect(find.text('# 789012'), findsOneWidget);
    await tester.tap(find.text('Petit Poussin'));
    await tester.pumpAndSettle();
    expect(find.text('Compte Démo'), findsNothing);
    await tester.tap(find.text('Accueil').last);
    await tester.pumpAndSettle();
    expect(find.text('PAUSE'), findsOneWidget);
    expect(find.text('La surveillance ne répond plus'), findsOneWidget);

    await tester.tap(find.text('Petit Poussin'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ajouter un compte'));
    await tester.pumpAndSettle();
    expect(find.textContaining('QR code'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
