import 'package:flutter/material.dart';

import '../models/account.dart';
import '../theme/theme.dart';

/// Rond coloré à l'initiale du compte.
class AccountAvatar extends StatelessWidget {
  const AccountAvatar(this.account, {super.key, this.size = 36});

  final AccountSnapshot account;
  final double size;

  @override
  Widget build(BuildContext context) {
    final mp = context.mp;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: mp.vivid(account.tone).withValues(alpha: 0.16),
        shape: BoxShape.circle,
      ),
      child: Text(
        account.initial,
        style: TextStyle(
          fontSize: size * 0.46,
          fontWeight: FontWeight.w700,
          color: mp.ink(account.tone),
        ),
      ),
    );
  }
}

/// Menu déroulant des comptes, dans l'en-tête : le compte affiché, puis la
/// liste et « Ajouter un compte ».
class AccountSwitcher extends StatelessWidget {
  const AccountSwitcher({
    super.key,
    required this.accounts,
    required this.selected,
    required this.onSelect,
    required this.onAdd,
  });

  final List<AccountSnapshot> accounts;
  final int selected;
  final ValueChanged<int> onSelect;
  final VoidCallback onAdd;

  static const _add = -1;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final current = accounts[selected];
    return PopupMenuButton<int>(
      tooltip: 'Changer de compte',
      position: PopupMenuPosition.under,
      offset: const Offset(0, MpSpace.sm),
      constraints: const BoxConstraints(minWidth: 300, maxWidth: 340),
      color: colors.surfaceContainerLowest,
      elevation: 6,
      shadowColor: colors.shadow.withValues(alpha: 0.3),
      shape: const RoundedRectangleBorder(borderRadius: MpRadius.card),
      menuPadding: const EdgeInsets.symmetric(vertical: MpSpace.sm),
      onSelected: (i) => i == _add ? onAdd() : onSelect(i),
      itemBuilder: (context) => [
        for (final (i, account) in accounts.indexed)
          PopupMenuItem(
            value: i,
            padding: const EdgeInsets.symmetric(horizontal: MpSpace.sm),
            height: 64,
            child: _AccountRow(account, selected: i == selected),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _add,
          padding: const EdgeInsets.symmetric(horizontal: MpSpace.lg),
          height: 60,
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: context.mp.bubble,
                  shape: BoxShape.circle,
                ),
                child: Icon(MpIcons.add, color: colors.onSurface),
              ),
              const SizedBox(width: MpSpace.md + 2),
              Flexible(
                child: Text(
                  'Ajouter un compte',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodyLarge,
                ),
              ),
            ],
          ),
        ),
      ],
      child: _CurrentAccount(current),
    );
  }
}

/// Le compte affiché, en pastille : avatar, nom, courtier, chevron.
class _CurrentAccount extends StatelessWidget {
  const _CurrentAccount(this.account);

  final AccountSnapshot account;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: colors.surfaceContainerLowest,
        shape: StadiumBorder(side: BorderSide(color: colors.outlineVariant)),
        shadows: context.mp.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(5, 5, MpSpace.md, 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AccountAvatar(account),
            const SizedBox(width: MpSpace.sm + 2),
            Flexible(child: _Names(account)),
            const SizedBox(width: MpSpace.sm),
            Icon(MpIcons.chevronDown, color: colors.primary),
          ],
        ),
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow(this.account, {required this.selected});

  final AccountSnapshot account;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final row = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: MpSpace.md,
        vertical: MpSpace.sm,
      ),
      child: Row(
        children: [
          AccountAvatar(account, size: 40),
          const SizedBox(width: MpSpace.md),
          Expanded(child: _Names(account)),
          Text(
            '# ${account.login}',
            style: context.text.bodySmall!.figures.copyWith(
              color: context.mp.textMuted,
            ),
          ),
          const SizedBox(width: MpSpace.sm),
          SizedBox(
            width: 22,
            child: selected
                ? Icon(MpIcons.check, size: 22, color: colors.primary)
                : null,
          ),
        ],
      ),
    );
    if (!selected) return row;
    // Compte affiché : fond orangé et filet orange à gauche.
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(MpRadius.md - 2)),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.primary.withValues(alpha: 0.1),
          border: Border(left: BorderSide(color: colors.primary, width: 4)),
        ),
        child: row,
      ),
    );
  }
}

class _Names extends StatelessWidget {
  const _Names(this.account);

  final AccountSnapshot account;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          account.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.text.titleSmall,
        ),
        Text(
          '${account.broker} • ${account.platform}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.text.bodySmall!.copyWith(color: context.mp.textMuted),
        ),
      ],
    );
  }
}
