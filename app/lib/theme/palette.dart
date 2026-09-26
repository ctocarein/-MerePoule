import 'package:flutter/painting.dart';

/// Couleurs brutes de la marque, relevées sur les maquettes de l'app.
///
/// Les écrans ne s'en servent pas directement : ils passent par le thème,
/// `context.colors` ([ColorScheme]) et `context.mp` ([MpColors]), qui
/// choisit la bonne teinte en clair et en sombre.
///
/// Les couleurs vives (orange, vert, rouge) vont aux aplats, icônes, jauges
/// et grands chiffres ; leurs variantes « texte », plus foncées, aux petits
/// textes, pour rester lisibles sur fond blanc.
abstract final class MpPalette {
  // Clair.
  static const page = Color(0xFFF6F7FA);
  static const card = Color(0xFFFFFFFF);
  static const segment = Color(0xFFEEF0F4);
  static const bubble = Color(0xFFF0F2F6);
  static const line = Color(0xFFDFE4EC);
  static const track = Color(0xFFD8DEE8);
  static const ink = Color(0xFF101522);
  static const muted = Color(0xFF626D80);
  static const faint = Color(0xFF9AA3B5);

  // Sombre.
  static const night = Color(0xFF101522);
  static const nightCard = Color(0xFF181E2D);
  static const nightRaised = Color(0xFF20283A);
  static const nightLine = Color(0xFF2A3244);
  static const nightTrack = Color(0xFF2E3748);
  static const snow = Color(0xFFF4F5F8);

  // Orange de la marque.
  static const orange = Color(0xFFFF9F1C);
  static const orangeLine = Color(0xFFFFAD21);
  static const orangeText = Color(0xFFA85A00);
  static const orangeSoft = Color(0xFFFFF1DD);

  // Signaux.
  static const green = Color(0xFF16C784);
  static const greenText = Color(0xFF087F53);
  static const red = Color(0xFFE5484D);
  static const redText = Color(0xFFC8262E);
  static const redNight = Color(0xFFFF6B70);
  static const blue = Color(0xFF0374FE);
  static const blueText = Color(0xFF0062D6);
  static const blueNight = Color(0xFF5AA2FF);

  /// Bouton STOP, identique en clair et en sombre, texte blanc.
  static const stop = Color(0xFFD92D35);

  /// Bouton « Continuer avec Telegram » des maquettes.
  static const telegram = Color(0xFF0094FE);
}
