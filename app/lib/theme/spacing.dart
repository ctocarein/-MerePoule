import 'package:flutter/widgets.dart';

/// Espacements, sur une grille de 4.
abstract final class MpSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// Marge gauche et droite d'un écran.
  static const double gutter = 20;

  /// Marge autour du contenu d'un écran ; en bas, la place du bouton rond.
  static const EdgeInsets screen = EdgeInsets.fromLTRB(gutter, sm, gutter, 96);
}

/// Arrondis des coins.
abstract final class MpRadius {
  static const double sm = 8;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 28;

  /// Boutons, champs, segments.
  static const BorderRadius control = BorderRadius.all(Radius.circular(md));

  /// Cartes.
  static const BorderRadius card = BorderRadius.all(Radius.circular(lg));

  /// Pastilles, jauges.
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
}
