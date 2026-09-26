import 'package:flutter/material.dart';

/// Famille déclarée dans `pubspec.yaml`.
abstract final class MpFonts {
  /// Noto Sans : proche de la police des maquettes, chiffres de largeur fixe.
  static const text = 'NotoSans';
}

/// Échelle de texte de l'app, relevée sur les maquettes. Les couleurs sont
/// posées par le thème.
abstract final class MpTypography {
  static const _heavy = FontWeight.w800;

  static const TextTheme textTheme = TextTheme(
    // Grands chiffres : equity, distance au stop-out.
    displayLarge: TextStyle(
      fontSize: 40,
      height: 1.1,
      fontWeight: _heavy,
      letterSpacing: -0.8,
    ),
    displayMedium: TextStyle(
      fontSize: 34,
      height: 1.1,
      fontWeight: _heavy,
      letterSpacing: -0.6,
    ),
    displaySmall: TextStyle(
      fontSize: 30,
      height: 1.15,
      fontWeight: _heavy,
      letterSpacing: -0.5,
    ),
    // Titre d'écran : « Tableau de bord ».
    headlineLarge: TextStyle(
      fontSize: 28,
      height: 1.2,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
    ),
    // État RUN, PAUSE, KILL.
    headlineMedium: TextStyle(
      fontSize: 26,
      height: 1.2,
      fontWeight: _heavy,
      letterSpacing: -0.3,
    ),
    // Chiffre d'une carte : solde, marge.
    headlineSmall: TextStyle(
      fontSize: 22,
      height: 1.25,
      fontWeight: _heavy,
      letterSpacing: -0.3,
    ),
    // Titre de carte : « Jauges de risque ».
    titleLarge: TextStyle(
      fontSize: 18,
      height: 1.3,
      fontWeight: FontWeight.w700,
    ),
    // Ligne du Journal.
    titleMedium: TextStyle(
      fontSize: 16,
      height: 1.35,
      fontWeight: FontWeight.w700,
    ),
    titleSmall: TextStyle(
      fontSize: 14,
      height: 1.35,
      fontWeight: FontWeight.w700,
    ),
    bodyLarge: TextStyle(
      fontSize: 16,
      height: 1.5,
      fontWeight: FontWeight.w400,
    ),
    bodyMedium: TextStyle(
      fontSize: 14,
      height: 1.45,
      fontWeight: FontWeight.w400,
    ),
    bodySmall: TextStyle(
      fontSize: 13,
      height: 1.4,
      fontWeight: FontWeight.w400,
    ),
    labelLarge: TextStyle(
      fontSize: 15,
      height: 1.3,
      fontWeight: FontWeight.w700,
    ),
    // Onglets, segments.
    labelMedium: TextStyle(
      fontSize: 13,
      height: 1.3,
      fontWeight: FontWeight.w600,
    ),
    labelSmall: TextStyle(
      fontSize: 11,
      height: 1.3,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.5,
    ),
  );
}

extension MpTextStyle on TextStyle {
  /// Chiffres alignés : montants, pourcentages, âges.
  /// `context.text.headlineSmall!.figures`
  TextStyle get figures =>
      copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
}
