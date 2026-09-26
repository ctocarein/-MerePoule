import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../widgets/brand.dart';
import '../widgets/google_logo.dart';
import '../widgets/mp_card.dart';

/// Connexion. Tailscale est le mode personnel ; Google et Telegram arrivent
/// avec le relais cloud (mode produit).
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key, required this.onTailscale});

  final VoidCallback onTailscale;

  void _soon(BuildContext context, String what) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '$what arrive bientôt. En attendant, connectez-vous par Tailscale.',
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final mp = context.mp;
    final muted = context.text.bodyLarge!.copyWith(color: mp.textMuted);
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _WavesPainter(context.colors.primary)),
          ),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                MpSpace.gutter,
                MpSpace.md,
                MpSpace.gutter,
                MpSpace.xl,
              ),
              children: [
                const Align(
                  alignment: Alignment.centerRight,
                  child: _LanguageChip(),
                ),
                const SizedBox(height: MpSpace.xxl),
                const Center(child: MpLogo(height: 104)),
                const SizedBox(height: MpSpace.lg),
                const Center(child: MpWordmark(size: 34)),
                const SizedBox(height: MpSpace.md),
                Text(
                  'Votre robot trade.\nPuissant comme MT5,\nsimplement pour vous.',
                  textAlign: TextAlign.center,
                  style: muted,
                ),
                const SizedBox(height: MpSpace.xxl + 8),
                OutlinedButton.icon(
                  onPressed: () => _soon(context, 'La connexion Google'),
                  icon: const GoogleLogo(),
                  label: const Text('Continuer avec Google'),
                ),
                const SizedBox(height: MpSpace.md),
                FilledButton.icon(
                  onPressed: () => _soon(context, 'La connexion Telegram'),
                  style: FilledButton.styleFrom(
                    backgroundColor: MpPalette.telegram,
                    foregroundColor: Colors.white,
                  ),
                  icon: Transform.rotate(
                    angle: -0.45,
                    child: const Icon(MpIcons.telegram, size: 20),
                  ),
                  label: const Text('Continuer avec Telegram'),
                ),
                const SizedBox(height: MpSpace.lg),
                const _OrDivider(),
                const SizedBox(height: MpSpace.lg),
                OutlinedButton.icon(
                  onPressed: onTailscale,
                  icon: const Icon(MpIcons.tailscale, size: 20),
                  label: const Text('Connexion par Tailscale'),
                ),
                const SizedBox(height: MpSpace.xxl + 8),
                MpCard(
                  padding: const EdgeInsets.all(MpSpace.lg),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(MpIcons.lock, color: context.colors.primary),
                      const SizedBox(width: MpSpace.md),
                      Expanded(
                        child: Text(
                          'Consulter est libre. Pour agir, MerePoule demande '
                          'votre empreinte, et votre code PIN pour une relance.',
                          style: context.text.bodySmall!.copyWith(
                            color: mp.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LanguageChip extends StatelessWidget {
  const _LanguageChip();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Langue : français',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.colors.surfaceContainerLowest,
          borderRadius: MpRadius.control,
          border: Border.all(color: context.colors.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MpSpace.md,
            vertical: MpSpace.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(MpIcons.language, size: 16),
              const SizedBox(width: MpSpace.xs + 2),
              Text('FR', style: context.text.labelMedium),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: MpSpace.md),
          child: Text(
            'ou',
            style: context.text.bodyMedium!.copyWith(
              color: context.mp.textMuted,
            ),
          ),
        ),
        const Expanded(child: Divider()),
      ],
    );
  }
}

/// Vagues orangées du fond, de part et d'autre du logo.
class _WavesPainter extends CustomPainter {
  _WavesPainter(this.orange);

  final Color orange;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    Paint fill(Alignment from, Alignment to) => Paint()
      ..shader = LinearGradient(
        begin: from,
        end: to,
        colors: [orange.withValues(alpha: 0.16), orange.withValues(alpha: 0)],
      ).createShader(Offset.zero & size);

    final left = Path()
      ..moveTo(0, h * 0.08)
      ..quadraticBezierTo(w * 0.42, h * 0.16, w * 0.18, h * 0.3)
      ..quadraticBezierTo(w * 0.02, h * 0.38, 0, h * 0.44)
      ..close();
    canvas.drawPath(left, fill(Alignment.topLeft, Alignment.center));

    final right = Path()
      ..moveTo(w, h * 0.14)
      ..quadraticBezierTo(w * 0.55, h * 0.24, w * 0.8, h * 0.36)
      ..quadraticBezierTo(w * 0.95, h * 0.42, w, h * 0.5)
      ..close();
    canvas.drawPath(right, fill(Alignment.topRight, Alignment.center));
  }

  @override
  bool shouldRepaint(_WavesPainter old) => old.orange != orange;
}
