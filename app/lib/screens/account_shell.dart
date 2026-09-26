import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/account.dart';
import '../theme/theme.dart';
import '../widgets/account_switcher.dart';
import '../widgets/brand.dart';
import 'balance_screen.dart';
import 'home_screen.dart';
import 'journal_screen.dart';
import 'news_screen.dart';
import 'robot_screen.dart';
import 'settings_screen.dart';
import 'style_guide_screen.dart';

/// Écrans des comptes, comme sur les maquettes : en-tête avec le menu
/// déroulant des comptes, quatre onglets en bas, le bouton rond orange, et
/// le menu en haut à droite pour Robot et Réglages.
class AccountShell extends StatefulWidget {
  const AccountShell({super.key, required this.accounts});

  /// Tous les comptes de toutes les passerelles enrôlées.
  final List<AccountData> accounts;

  @override
  State<AccountShell> createState() => _AccountShellState();
}

class _AccountShellState extends State<AccountShell> {
  int _account = 0;
  int _tab = 0;

  void _open(Widget screen, String title) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: SafeArea(child: screen),
        ),
      ),
    );
  }

  void _soon(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.accounts[_account];
    final colors = context.colors;
    // Une clé par compte et par onglet : changer de compte repart des
    // réglages par défaut (période, filtres) de chaque écran.
    Key key(String tab) => ValueKey('${data.account.login}/$tab');
    return Scaffold(
      endDrawer: _Menu(accountLabel: data.account.label, onOpen: _open),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(
              switcher: AccountSwitcher(
                accounts: [for (final d in widget.accounts) d.account],
                selected: _account,
                onSelect: (i) => setState(() => _account = i),
                onAdd: () => _soon(
                  'Bientôt : ajouter un compte en scannant le QR code de sa '
                  'passerelle.',
                ),
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [
                  HomeScreen(key: key('home'), data: data),
                  BalanceScreen(
                    key: key('balance'),
                    account: data.account,
                    history: data.history[Metric.equity] ?? const {},
                  ),
                  NewsScreen(
                    key: key('news'),
                    items: data.news,
                    age: data.newsAge,
                  ),
                  JournalScreen(key: key('journal'), events: data.journal),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: _PowerButton(
        onPressed: () => _soon(
          'Bientôt disponible. En attendant, pilotez depuis Telegram : '
          '/kill pour tout arrêter, /relancer pour repartir.',
        ),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.outlineVariant)),
        ),
        child: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(MpIcons.home), label: 'Accueil'),
            NavigationDestination(icon: Icon(MpIcons.balance), label: 'Solde'),
            NavigationDestination(
              icon: Icon(MpIcons.news),
              label: 'Actualités',
            ),
            NavigationDestination(
              icon: Icon(MpIcons.journal),
              label: 'Journal',
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.switcher});

  final Widget switcher;

  /// En dessous, le nom MerePoule laisse sa place au menu des comptes.
  static const _wordmarkWidth = 560.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MpSpace.gutter,
        MpSpace.md,
        MpSpace.gutter,
        MpSpace.xs,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            const MpLogoBadge(),
            if (constraints.maxWidth >= _wordmarkWidth) ...[
              const SizedBox(width: MpSpace.md),
              const MpWordmark(size: 24),
            ],
            const SizedBox(width: MpSpace.md),
            Expanded(
              child: Align(alignment: Alignment.centerRight, child: switcher),
            ),
            const SizedBox(width: MpSpace.sm + 2),
            Tooltip(
              message: 'Menu',
              child: Material(
                color: colors.surfaceContainerLowest,
                shape: CircleBorder(
                  side: BorderSide(color: colors.outlineVariant),
                ),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Scaffold.of(context).openEndDrawer(),
                  child: const SizedBox.square(
                    dimension: 46,
                    child: Icon(MpIcons.menu, size: 22),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bouton rond orange des maquettes. Plus d'écran Commandes : son rôle
/// reste à décider.
class _PowerButton extends StatelessWidget {
  const _PowerButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final orange = context.colors.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
            color: orange.withValues(alpha: 0.45),
            blurRadius: 24,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: FloatingActionButton(
        onPressed: onPressed,
        tooltip: 'Bientôt disponible',
        child: const Icon(MpIcons.power, size: 28),
      ),
    );
  }
}

class _Menu extends StatelessWidget {
  const _Menu({required this.accountLabel, required this.onOpen});

  final String accountLabel;
  final void Function(Widget screen, String title) onOpen;

  @override
  Widget build(BuildContext context) {
    void go(VoidCallback action) {
      Navigator.of(context).pop();
      action();
    }

    ListTile item(
      IconData icon,
      String title,
      String subtitle,
      VoidCallback onTap,
    ) {
      return ListTile(
        leading: Icon(icon),
        title: Text(title, style: context.text.titleMedium),
        subtitle: Text(subtitle),
        onTap: () => go(onTap),
      );
    }

    return Drawer(
      child: SafeArea(
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MpSpace.gutter,
                MpSpace.lg,
                MpSpace.sm,
                MpSpace.lg,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const MpWordmark(size: 22),
                        Text(
                          accountLabel,
                          style: context.text.bodySmall!.copyWith(
                            color: context.mp.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Fermer',
                    icon: const Icon(MpIcons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(),
            item(
              MpIcons.robot,
              'Robot',
              'Graphiques, santé et réglages',
              () => onOpen(const RobotScreen(), 'Robot'),
            ),
            item(
              MpIcons.settings,
              'Réglages',
              'Seuils, téléphones, notifications',
              () => onOpen(const SettingsScreen(), 'Réglages'),
            ),
            // Pour le développement seulement : absent des versions publiées.
            if (kDebugMode)
              item(
                MpIcons.styleGuide,
                'Charte graphique',
                'Couleurs, polices et icônes de l’app',
                () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const StyleGuideScreen()),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
