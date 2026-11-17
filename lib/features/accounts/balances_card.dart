import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/icons.dart';
import '../../core/theme/palette.dart';
import '../../data/db/database.dart';
import '../../data/db/extras.dart';
import '../../providers.dart';
import '../../providers_extra.dart';
import '../../ui/amount_field.dart';
import '../../ui/widgets.dart';
import '../bills/bill_schedule.dart';
import '../settings/manage_widgets.dart';

/// "Balance as of 2 days ago" — the balance stated by the account's latest message.
String balanceAsOf(Account a) {
  if (a.balanceAt == null) return '';
  return '${a.balanceManual ? 'set by you' : 'from last SMS'} · ${relativeTime(a.balanceAt!)}';
}

/// Lets the user type a balance (or clear it). Returns when done.
Future<void> showBalanceDialog(BuildContext context, WidgetRef ref, Account a) async {
  final ctrl = TextEditingController(text: a.balanceMinor == null ? '' : plainAmount(a.balanceMinor!, a.currency));
  final db = ref.read(databaseProvider);
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('${a.name} balance'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Balances update by themselves whenever a bank message states one. Type one here if you know it; '
            'a newer message will replace it.',
            style: c.text.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.numberWithOptions(decimal: currencyDigits(a.currency) > 0),
            inputFormatters: [AmountInputFormatter(currency: a.currency)],
            decoration: InputDecoration(prefixText: '${currencySymbol(a.currency)} '),
          ),
        ],
      ),
      actions: [
        if (a.balanceMinor != null)
          TextButton(
            onPressed: () async {
              await db.clearBalance(a.id);
              if (c.mounted) Navigator.pop(c);
            },
            child: const Text('Clear'),
          ),
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        TextButton(
          onPressed: () async {
            final minor = parseAmountInput(ctrl.text, currency: a.currency);
            if (minor != null) await db.applyBalance(a.id, minor, DateTime.now(), manual: true);
            if (c.mounted) Navigator.pop(c);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Dashboard card: every account's balance as per its last message.
class BalancesCard extends ConsumerWidget {
  const BalancesCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = (ref.watch(accountsProvider).value ?? const <Account>[]).where((a) => a.balanceMinor != null).toList();
    if (accounts.isEmpty) return const SizedBox.shrink();
    final totals = balanceTotals(accounts);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader('Account balances', action: 'Manage', onAction: () => context.push('/settings/accounts')),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Column(
              children: [
                if (accounts.where((a) => a.kind != AccountKind.creditCard).length > 1)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Total across accounts'),
                    trailing: Text(money(totals.total), style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                  ),
                for (final a in accounts)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: AccountBadge(account: a, size: 38),
                    title: Text(accountLabel(a), maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(balanceAsOf(a), style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant)),
                    trailing: Text(
                      money(a.balanceMinor!, currency: a.currency, forceDecimals: true),
                      style: context.text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    onTap: () => showBalanceDialog(context, ref, a),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Dashboard card: bills due soon or overdue.
class UpcomingBillsCard extends ConsumerWidget {
  const UpcomingBillsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = DateTime.now();
    final bills = (ref.watch(billsProvider).value ?? const <Bill>[])
        .where((b) => b.active && daysUntil(b.nextDue, today) <= 7)
        .take(3)
        .toList();
    if (bills.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader('Coming up', action: 'All bills', onAction: () => context.push('/bills')),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Column(
              children: [
                for (final b in bills)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      PhosphorIconsFill.bellRinging,
                      color: daysUntil(b.nextDue, today) < 0 ? Palette.coral : Palette.amber,
                    ),
                    title: Text(b.name),
                    subtitle: Text(dueLabel(b.nextDue, today)),
                    trailing: b.amountMinor > 0 ? Text(money(b.amountMinor, currency: b.currency)) : null,
                    onTap: () => context.push('/bills'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
