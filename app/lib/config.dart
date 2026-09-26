import 'package:flutter/material.dart';

/// Réglages de l'app fixés à la compilation.
abstract final class MpConfig {
  static const appName = 'MerePoule';

  /// Thème clair des maquettes ; le sombre existe mais n'est pas proposé.
  static const themeMode = ThemeMode.light;

  /// L'app n'existe qu'en français.
  static const locale = Locale('fr', 'FR');

  /// Bandeau de confiance vert tant que le statut a moins de 5 s
  /// (spécification, Composant 3).
  static const freshStatus = Duration(seconds: 5);
}
