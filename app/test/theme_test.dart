import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:merepoule/theme/theme.dart';

/// Contraste WCAG entre deux couleurs opaques.
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final (hi, lo) = la > lb ? (la, lb) : (lb, la);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  for (final (name, theme) in [
    ('clair', MpTheme.light),
    ('sombre', MpTheme.dark),
  ]) {
    group('thème $name', () {
      final c = theme.colorScheme;
      final mp = theme.extension<MpColors>()!;
      final backgrounds = {'fond': c.surface, 'carte': c.surfaceContainer};

      // Petit texte : 4,5 au moins (WCAG AA) sur les fonds et les cartes.
      // Les teintes vives (orange, vert) ne servent qu'en grand ou en aplat.
      final texts = {
        'encre': c.onSurface,
        'secondaire': c.onSurfaceVariant,
        'discret': mp.textMuted,
        'orange texte': mp.accentText,
        'vert texte': mp.okText,
        'orange attention texte': mp.attentionText,
        'rouge texte': mp.dangerText,
      };
      for (final MapEntry(key: bgName, value: bg) in backgrounds.entries) {
        for (final MapEntry(key: fgName, value: fg) in texts.entries) {
          test('$fgName sur $bgName', () {
            expect(contrast(fg, bg), greaterThanOrEqualTo(4.5));
          });
        }
      }

      test('textes posés sur l’orange et sur STOP', () {
        expect(contrast(c.onPrimary, c.primary), greaterThanOrEqualTo(4.5));
        expect(contrast(mp.onStop, mp.stop), greaterThanOrEqualTo(4.5));
      });

      test('police de la marque', () {
        expect(theme.textTheme.bodyLarge!.fontFamily, MpFonts.text);
        expect(theme.textTheme.headlineLarge!.fontFamily, MpFonts.text);
        expect(theme.textTheme.bodyLarge!.color, c.onSurface);
      });
    });
  }

  test('chiffres alignés', () {
    const style = TextStyle(fontFamily: MpFonts.text);
    expect(
      style.figures.fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );
  });
}
