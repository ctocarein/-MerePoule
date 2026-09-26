import 'package:flutter/material.dart';

import '../demo/demo_data.dart';
import '../models/account.dart';
import '../models/account_state.dart';
import '../theme/theme.dart';
import '../widgets/account_switcher.dart';
import '../widgets/amount_text.dart';
import '../widgets/brand.dart';
import '../widgets/eyebrow.dart';
import '../widgets/gauge_bar.dart';
import '../widgets/icon_bubble.dart';
import '../widgets/metric_card.dart';
import '../widgets/pill.dart';
import '../widgets/segmented.dart';
import '../widgets/state_badge.dart';
import '../widgets/trend_card.dart';
import '../widgets/trust_banner.dart';

/// Vitrine de la charte : logo, couleurs, textes, chiffres, états, bandeau,
/// jauges, sélecteur, boutons et icônes, dans le thème en cours. Chiffres
/// d'exemple.
class StyleGuideScreen extends StatelessWidget {
  const StyleGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Charte graphique')),
      body: SafeArea(
        child: ListView(
          padding: MpSpace.screen,
          children: const [
            _Section('Logo', child: _Brand()),
            _Section('Couleurs', child: _Colors()),
            _Section('Textes', child: _Fonts()),
            _Section('Chiffres', child: _Figures()),
            _Section('Carte à courbe', child: _Trend()),
            _Section('Pastilles et comptes', child: _Pills()),
            _Section('États du compte', child: _States()),
            _Section('Bandeau de confiance', child: _Banners()),
            _Section('Jauges', child: _Gauges()),
            _Section('Sélecteur', child: _Segments()),
            _Section('Boutons', child: _Buttons()),
            _Section('Icônes', child: _Icons()),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, {required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: MpSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Eyebrow(title),
          const SizedBox(height: MpSpace.md),
          child,
        ],
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    return const Wrap(
      spacing: MpSpace.xl,
      runSpacing: MpSpace.lg,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [MpLogo(height: 72), MpLogoBadge(), MpWordmark(size: 28)],
    );
  }
}

class _Colors extends StatelessWidget {
  const _Colors();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final mp = context.mp;
    final swatches = [
      ('Fond', c.surface),
      ('Carte', c.surfaceContainer),
      ('Encre', c.onSurface),
      ('Texte discret', mp.textMuted),
      ('Filet', c.outlineVariant),
      ('Orange', c.primary),
      ('Orange texte', mp.accentText),
      ('Vert', mp.ok),
      ('Vert texte', mp.okText),
      ('Rouge', mp.danger),
      ('Rouge texte', mp.dangerText),
      ('Bleu', mp.info),
      ('Bleu texte', mp.infoText),
      ('Bouton STOP', mp.stop),
    ];
    return Wrap(
      spacing: MpSpace.md,
      runSpacing: MpSpace.lg,
      children: [
        for (final (name, color) in swatches)
          SizedBox(
            width: 96,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: const BorderRadius.all(
                      Radius.circular(MpRadius.sm),
                    ),
                    border: Border.all(color: c.outlineVariant),
                  ),
                ),
                const SizedBox(height: MpSpace.xs),
                Text(name, style: context.text.labelMedium),
                Text(
                  _hex(color),
                  style: context.text.bodySmall!.figures.copyWith(
                    color: mp.textMuted,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _hex(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
}

class _Fonts extends StatelessWidget {
  const _Fonts();

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    final muted = t.bodySmall!.copyWith(color: context.mp.textMuted);
    final samples = [
      ('displayMedium · grand chiffre', '7 173,06 \$', t.displayMedium),
      ('headlineLarge · titre d’écran', 'Tableau de bord', t.headlineLarge),
      ('headlineMedium · état', 'RUN', t.headlineMedium),
      ('headlineSmall · chiffre de carte', '2 614,85 \$', t.headlineSmall),
      ('titleLarge · titre de carte', 'Jauges de risque', t.titleLarge),
      ('titleMedium · ligne', 'PAUSE demandée', t.titleMedium),
      ('bodyMedium', 'Votre robot veille sur votre capital.', t.bodyMedium),
      ('bodySmall', 'Positions fermées · bilan envoyé', t.bodySmall),
      ('labelLarge · boutons', 'Connexion par Tailscale', t.labelLarge),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Noto Sans, graisses 400 à 800', style: muted),
        const SizedBox(height: MpSpace.md),
        for (final (role, text, style) in samples) ...[
          Text(role, style: muted),
          Text(text, style: style),
          const SizedBox(height: MpSpace.md),
        ],
      ],
    );
  }
}

class _Figures extends StatelessWidget {
  const _Figures();

  @override
  Widget build(BuildContext context) {
    final value = context.text.headlineSmall!;
    final small = context.text.bodyMedium!;
    return MetricRow(
      MetricCard(
        label: 'Gain latent',
        value: AmountText(286, currency: 'USD', style: value),
        footer: AmountText(286, currency: 'USD', style: small),
      ),
      MetricCard(
        label: 'Perte flottante',
        value: AmountText(-440.37, currency: 'USD', style: value),
        footer: AmountText(-440.37, currency: 'USD', style: small),
      ),
    );
  }
}

class _Trend extends StatelessWidget {
  const _Trend();

  @override
  Widget build(BuildContext context) {
    final data = Demo.accounts.first;
    return TrendCard(
      icon: MpIcons.wallet,
      label: 'Solde',
      tone: Tone.green,
      history: data.history[Metric.balance]!,
      changeCurrency: 'USD',
      value: AmountText(
        data.account.balance,
        currency: 'USD',
        style: context.text.displaySmall,
        signed: false,
        colored: false,
      ),
    );
  }
}

class _Pills extends StatelessWidget {
  const _Pills();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: MpSpace.sm,
      runSpacing: MpSpace.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const TrendPill(percent: 21.3, tone: Tone.green),
        const TrendPill(percent: 18.7, tone: Tone.orange),
        const TrendPill(percent: 5.2, tone: Tone.blue),
        const TrendPill(percent: -3.2, tone: Tone.green),
        const MpPill(
          tone: Tone.orange,
          icon: MpIcons.clock,
          text: 'Tendance positive',
        ),
        for (final d in Demo.accounts) AccountAvatar(d.account),
      ],
    );
  }
}

class _States extends StatelessWidget {
  const _States();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final state in AccountState.values)
          Padding(
            padding: const EdgeInsets.only(bottom: MpSpace.md),
            child: Row(
              children: [
                StateBadge(state),
                const SizedBox(width: MpSpace.md),
                Expanded(
                  child: Text(state.meaning, style: context.text.bodySmall),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Banners extends StatelessWidget {
  const _Banners();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TrustBanner(level: TrustLevel.live, age: Duration(seconds: 2)),
        SizedBox(height: MpSpace.sm),
        TrustBanner(
          level: TrustLevel.watchdogSilent,
          age: Duration(minutes: 3),
        ),
        SizedBox(height: MpSpace.sm),
        TrustBanner(level: TrustLevel.unreachable, age: Duration(minutes: 12)),
      ],
    );
  }
}

class _Gauges extends StatelessWidget {
  const _Gauges();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        GaugeBar(
          RiskGauge(
            label: 'Tranquille',
            value: '3 % sur 20 %',
            fraction: 0.15,
            level: GaugeLevel.calm,
          ),
        ),
        SizedBox(height: MpSpace.lg),
        GaugeBar(
          RiskGauge(
            label: 'Proche du seuil',
            value: '452 % · alerte sous 500 %',
            fraction: 0.9,
            level: GaugeLevel.near,
          ),
        ),
        SizedBox(height: MpSpace.lg),
        GaugeBar(
          RiskGauge(
            label: 'Seuil franchi',
            value: '−452 \$ sur −440 \$',
            fraction: 1,
            level: GaugeLevel.crossed,
          ),
        ),
      ],
    );
  }
}

class _Segments extends StatefulWidget {
  const _Segments();

  @override
  State<_Segments> createState() => _SegmentsState();
}

class _SegmentsState extends State<_Segments> {
  BalancePeriod _period = BalancePeriod.week;

  @override
  Widget build(BuildContext context) {
    return MpSegmented<BalancePeriod>(
      values: BalancePeriod.values,
      label: (p) => p.label,
      selected: _period,
      onChanged: (p) => setState(() => _period = p),
    );
  }
}

class _Buttons extends StatelessWidget {
  const _Buttons();

  @override
  Widget build(BuildContext context) {
    final mp = context.mp;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: () {},
          icon: const Icon(MpIcons.relaunch),
          label: const Text('Relancer'),
        ),
        const SizedBox(height: MpSpace.sm),
        OutlinedButton.icon(
          onPressed: () {},
          icon: const Icon(MpIcons.pauseAction),
          label: const Text('Mettre en pause'),
        ),
        const SizedBox(height: MpSpace.sm),
        FilledButton.icon(
          onPressed: () {},
          style: FilledButton.styleFrom(
            backgroundColor: mp.stop,
            foregroundColor: mp.onStop,
          ),
          icon: const Icon(MpIcons.stopAction),
          label: const Text('STOP : tout arrêter'),
        ),
        const SizedBox(height: MpSpace.sm),
        TextButton(onPressed: () {}, child: const Text('Annuler')),
      ],
    );
  }
}

class _Icons extends StatelessWidget {
  const _Icons();

  static const _icons = [
    (MpIcons.home, 'home'),
    (MpIcons.balance, 'balance'),
    (MpIcons.news, 'news'),
    (MpIcons.journal, 'journal'),
    (MpIcons.menu, 'menu'),
    (MpIcons.wallet, 'wallet'),
    (MpIcons.equity, 'equity'),
    (MpIcons.floating, 'floating'),
    (MpIcons.margin, 'margin'),
    (MpIcons.power, 'power'),
    (MpIcons.robot, 'robot'),
    (MpIcons.settings, 'settings'),
    (MpIcons.accounts, 'accounts'),
    (MpIcons.pauseAction, 'pauseAction'),
    (MpIcons.relaunch, 'relaunch'),
    (MpIcons.reset, 'reset'),
    (MpIcons.alert, 'alert'),
    (MpIcons.shield, 'shield'),
    (MpIcons.killed, 'killed'),
    (MpIcons.forex, 'forex'),
    (MpIcons.calendar, 'calendar'),
    (MpIcons.watchdogSilent, 'watchdogSilent'),
    (MpIcons.unreachable, 'unreachable'),
    (MpIcons.tailscale, 'tailscale'),
    (MpIcons.lock, 'lock'),
    (MpIcons.biometrics, 'biometrics'),
    (MpIcons.scanQr, 'scanQr'),
    (MpIcons.notifications, 'notifications'),
  ];

  @override
  Widget build(BuildContext context) {
    final label = context.text.bodySmall!.copyWith(
      color: context.mp.textMuted,
      fontSize: 10,
    );
    return Wrap(
      spacing: MpSpace.xs,
      runSpacing: MpSpace.md,
      children: [
        for (final (icon, name) in _icons)
          SizedBox(
            width: 76,
            child: Column(
              children: [
                IconBubble(icon),
                const SizedBox(height: MpSpace.xs),
                Text(
                  name,
                  style: label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
