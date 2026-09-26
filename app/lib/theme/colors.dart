import 'package:flutter/material.dart';

import 'palette.dart';

/// Couleurs de sens, en plus du [ColorScheme] de Material : vert, orange et
/// rouge des états, du bandeau de confiance et des jauges, gains et pertes,
/// STOP, ombre des cartes.
///
/// Chaque signal a deux teintes : vive ([ok]) pour un aplat, une icône, une
/// jauge ou un grand chiffre ; foncée ([okText]) pour un petit texte. Une
/// couleur ne porte jamais seule le message : toujours une icône ou un mot.
@immutable
class MpColors extends ThemeExtension<MpColors> {
  const MpColors({
    required this.ok,
    required this.okText,
    required this.attention,
    required this.attentionText,
    required this.danger,
    required this.dangerText,
    required this.info,
    required this.infoText,
    required this.accentText,
    required this.stop,
    required this.onStop,
    required this.textMuted,
    required this.track,
    required this.bubble,
    required this.cardShadow,
  });

  /// RUN, bandeau vert, jauge tranquille, gain.
  final Color ok;
  final Color okText;

  /// PAUSE, bandeau orange (Watchdog muet), jauge proche du seuil.
  final Color attention;
  final Color attentionText;

  /// KILL, bandeau rouge (passerelle injoignable), seuil franchi, perte.
  final Color danger;
  final Color dangerText;

  /// Niveau de marge.
  final Color info;
  final Color infoText;

  /// Orange de la marque en petit texte : onglet choisi, lien.
  final Color accentText;

  /// Fond du bouton STOP et texte posé dessus.
  final Color stop;
  final Color onStop;

  /// Texte discret : légendes, âges, sous-titres.
  final Color textMuted;

  /// Fond des jauges.
  final Color track;

  /// Rond gris derrière les icônes du Journal et de l'Actualité.
  final Color bubble;

  final List<BoxShadow> cardShadow;

  Color get gain => ok;
  Color get loss => danger;

  /// Fond teinté d'un signal, pour une pastille ou un bandeau.
  static Color tint(Color signal) => signal.withValues(alpha: 0.12);

  /// Teinte vive d'un ton : icône, courbe, avatar.
  Color vivid(Tone tone) => switch (tone) {
    Tone.green => ok,
    Tone.orange => attention,
    Tone.blue => info,
    Tone.red => danger,
    Tone.grey => textMuted,
  };

  /// Teinte foncée d'un ton, pour un petit texte.
  Color ink(Tone tone) => switch (tone) {
    Tone.green => okText,
    Tone.orange => attentionText,
    Tone.blue => infoText,
    Tone.red => dangerText,
    Tone.grey => textMuted,
  };

  static const light = MpColors(
    ok: MpPalette.green,
    okText: MpPalette.greenText,
    attention: MpPalette.orange,
    attentionText: MpPalette.orangeText,
    danger: MpPalette.red,
    dangerText: MpPalette.redText,
    info: MpPalette.blue,
    infoText: MpPalette.blueText,
    accentText: MpPalette.orangeText,
    stop: MpPalette.stop,
    onStop: Colors.white,
    textMuted: MpPalette.muted,
    track: MpPalette.track,
    bubble: MpPalette.bubble,
    cardShadow: [
      BoxShadow(color: Color(0x0A101522), blurRadius: 24, offset: Offset(0, 8)),
    ],
  );

  static const dark = MpColors(
    ok: MpPalette.green,
    okText: MpPalette.green,
    attention: MpPalette.orange,
    attentionText: MpPalette.orange,
    danger: MpPalette.red,
    dangerText: MpPalette.redNight,
    info: MpPalette.blueNight,
    infoText: MpPalette.blueNight,
    accentText: MpPalette.orange,
    stop: MpPalette.stop,
    onStop: Colors.white,
    textMuted: MpPalette.faint,
    track: MpPalette.nightTrack,
    bubble: MpPalette.nightRaised,
    cardShadow: [],
  );

  @override
  MpColors copyWith({
    Color? ok,
    Color? okText,
    Color? attention,
    Color? attentionText,
    Color? danger,
    Color? dangerText,
    Color? info,
    Color? infoText,
    Color? accentText,
    Color? stop,
    Color? onStop,
    Color? textMuted,
    Color? track,
    Color? bubble,
    List<BoxShadow>? cardShadow,
  }) {
    return MpColors(
      ok: ok ?? this.ok,
      okText: okText ?? this.okText,
      attention: attention ?? this.attention,
      attentionText: attentionText ?? this.attentionText,
      danger: danger ?? this.danger,
      dangerText: dangerText ?? this.dangerText,
      info: info ?? this.info,
      infoText: infoText ?? this.infoText,
      accentText: accentText ?? this.accentText,
      stop: stop ?? this.stop,
      onStop: onStop ?? this.onStop,
      textMuted: textMuted ?? this.textMuted,
      track: track ?? this.track,
      bubble: bubble ?? this.bubble,
      cardShadow: cardShadow ?? this.cardShadow,
    );
  }

  @override
  MpColors lerp(MpColors? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return MpColors(
      ok: mix(ok, other.ok),
      okText: mix(okText, other.okText),
      attention: mix(attention, other.attention),
      attentionText: mix(attentionText, other.attentionText),
      danger: mix(danger, other.danger),
      dangerText: mix(dangerText, other.dangerText),
      info: mix(info, other.info),
      infoText: mix(infoText, other.infoText),
      accentText: mix(accentText, other.accentText),
      stop: mix(stop, other.stop),
      onStop: mix(onStop, other.onStop),
      textMuted: mix(textMuted, other.textMuted),
      track: mix(track, other.track),
      bubble: mix(bubble, other.bubble),
      cardShadow: BoxShadow.lerpList(cardShadow, other.cardShadow, t)!,
    );
  }
}

/// Couleur d'une carte, d'un avatar ou d'une pastille.
enum Tone { green, orange, blue, red, grey }

/// Raccourcis : `context.mp.ok`, `context.colors.primary`, `context.text.bodyLarge`.
extension MpThemeContext on BuildContext {
  MpColors get mp => Theme.of(this).extension<MpColors>()!;
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;
}
