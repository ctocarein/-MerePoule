import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../utils/format.dart';

/// Montant aux chiffres alignés ; en vert s'il gagne, en rouge s'il perd,
/// quand [colored] est vrai. Vert vif en grand, vert foncé en petit.
class AmountText extends StatelessWidget {
  const AmountText(
    this.value, {
    super.key,
    this.currency,
    this.style,
    this.signed = true,
    this.colored = true,
    this.suffix = '',
  });

  final num value;

  /// Code de la devise du compte (`USD`, `EUR`…), ou rien.
  final String? currency;

  /// Taille du texte ; `bodyLarge` par défaut.
  final TextStyle? style;

  /// « + » devant un gain.
  final bool signed;

  final bool colored;

  /// Texte après le montant : « aujourd’hui ».
  final String suffix;

  @override
  Widget build(BuildContext context) {
    final mp = context.mp;
    final base = (style ?? context.text.bodyLarge!).figures;
    final large = (base.fontSize ?? 14) >= 20;
    final Color? color = !colored || value == 0
        ? null
        : value > 0
        ? (large ? mp.ok : mp.okText)
        : (large ? mp.danger : mp.dangerText);
    return Text(
      '${MpFormat.money(value, currency: currency, signed: signed)}$suffix',
      style: base.copyWith(color: color),
    );
  }
}
