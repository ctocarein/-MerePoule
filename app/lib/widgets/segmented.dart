import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// Sélecteur des maquettes : bande grise, choix en pastille blanche.
class MpSegmented<T> extends StatelessWidget {
  const MpSegmented({
    super.key,
    required this.values,
    required this.label,
    required this.selected,
    required this.onChanged,
  });

  final List<T> values;
  final String Function(T value) label;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = context.text.labelMedium!.copyWith(color: colors.onSurface);
    return Container(
      padding: const EdgeInsets.all(MpSpace.xs),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: MpRadius.control,
      ),
      child: Row(
        children: [
          for (final value in values)
            Expanded(
              child: _Segment(
                label: label(value),
                selected: value == selected,
                style: style,
                onTap: () => onChanged(value),
              ),
            ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.style,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final TextStyle style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(MpRadius.md - 4));
    return Semantics(
      button: true,
      selected: selected,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 40,
        decoration: BoxDecoration(
          color: selected ? context.colors.surfaceContainerLowest : null,
          borderRadius: radius,
          boxShadow: selected
              ? const [
                  BoxShadow(
                    color: Color(0x14101522),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: MpSpace.xs),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    style: style.copyWith(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
