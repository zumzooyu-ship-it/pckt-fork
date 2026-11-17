import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme/icons.dart';
import '../../core/theme/palette.dart';
import '../../data/db/database.dart';
import '../../data/db/extras.dart';
import '../../providers.dart';
import '../../providers_extra.dart';
import '../../ui/amount_field.dart';
import '../../ui/widgets.dart';
import 'transaction_sheet.dart' show showTransactionSheet;

/// "Split / repayments" block of the transaction screen. Shows on BOTH sides:
/// the payment (what came back, what is really yours) and the money received
/// (which payment it settles).
class LinksPanel extends ConsumerWidget {
  const LinksPanel({super.key, required this.txn});
  final Transaction txn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (txn.isTransfer) return const SizedBox.shrink();
    final links = ref.watch(linkViewsProvider(txn.id)).value ?? const <LinkView>[];
    final db = ref.read(databaseProvider);
    final isPayment = txn.direction == TxnDirection.debit;
    final free = txn.amountMinor - txn.linkedMinor;
    final c = txn.currency;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(isPayment ? 'Split & repayments' : 'Repayment of a payment'),
        if (links.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              isPayment
                  ? 'Paid for friends too? Link what they sent back (before or after) and only your share counts as spending.'
                  : 'Is this a friend paying you back, or a refund? Link it to the payment so it is not counted as income.',
              style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          )
        else ...[
          AppCard(
            color: Palette.mint.withValues(alpha: 0.10),
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                if (isPayment) ...[
                  _row(context, 'You paid', money(txn.amountMinor, currency: c)),
                  _row(context, 'Paid back to you', '− ${money(txn.linkedMinor, currency: c)}', color: Palette.mint),
                  const Divider(height: 18),
                  _row(
                    context,
                    'Your share',
                    money(txn.amountMinor - txn.linkedMinor, currency: c),
                    bold: true,
                  ),
                ] else ...[
                  _row(context, 'Received', money(txn.amountMinor, currency: c)),
                  _row(context, 'Repayment (not income)', money(txn.linkedMinor, currency: c), color: Palette.mint),
                  if (free > 0) _row(context, 'Not linked yet', money(free, currency: c)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          for (final l in links)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: Icon(isPayment ? PhosphorIconsBold.arrowDownLeft : PhosphorIconsBold.arrowUpRight, color: Palette.mint),
              title: Text(txnTitle(l.other)),
              subtitle: Text(
                '${dayLabel(l.other.occurredAt)} · ${money(l.link.amountMinor, currency: c)} of ${money(l.other.amountMinor, currency: c)}',
              ),
              onTap: () {
                Navigator.pop(context);
                showTransactionSheet(context, l.other.id);
              },
              trailing: IconButton(
                tooltip: 'Remove link',
                icon: const Icon(PhosphorIconsBold.minusCircle),
                onPressed: () => db.removeLink(l.link.id),
              ),
            ),
        ],
        OutlinedButton.icon(
          onPressed: free <= 0 ? null : () => showLinkSheet(context, txn),
          icon: const Icon(PhosphorIconsBold.plus, size: 18),
          label: Text(isPayment ? 'Link money received' : 'Link to a payment'),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, String l, String r, {Color? color, bool bold = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(child: Text(l, style: context.text.bodyMedium)),
        Text(
          r,
          style: context.text.bodyMedium?.copyWith(
            color: color,
            fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );
}

/// Pick the other end of a repayment and how much of it counts.
Future<void> showLinkSheet(BuildContext context, Transaction anchor) => showModalBottomSheet(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.8,
    maxChildSize: 0.95,
    builder: (_, scroll) => _LinkPicker(anchor: anchor, scroll: scroll),
  ),
);

class _LinkPicker extends ConsumerWidget {
  const _LinkPicker({required this.anchor, required this.scroll});
  final Transaction anchor;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.read(databaseProvider);
    final isPayment = anchor.direction == TxnDirection.debit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(isPayment ? 'Which money paid you back?' : 'Which payment is this for?', style: context.text.titleLarge),
              const SizedBox(height: 4),
              Text(
                isPayment
                    ? '${txnTitle(anchor)} · ${money(anchor.amountMinor - anchor.linkedMinor, currency: anchor.currency)} still to settle'
                    : '${txnTitle(anchor)} · ${money(anchor.amountMinor - anchor.linkedMinor, currency: anchor.currency)} not linked yet',
                style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Transaction>>(
            future: db.linkCandidates(anchor),
            builder: (context, snap) {
              final list = snap.data;
              if (list == null) return const Center(child: CircularProgressIndicator());
              if (list.isEmpty) {
                return const EmptyState(
                  icon: PhosphorIconsFill.handCoins,
                  title: 'Nothing to link yet',
                  message:
                      'No matching transactions within 90 days. When the other payment arrives, open it and link it '
                      'to this one.',
                );
              }
              return ListView.builder(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final t = list[i];
                  final left = t.amountMinor - t.linkedMinor;
                  return ListTile(
                    leading: Icon(
                      t.direction == TxnDirection.credit ? PhosphorIconsBold.arrowDownLeft : PhosphorIconsBold.arrowUpRight,
                      color: t.direction == TxnDirection.credit ? Palette.income : null,
                    ),
                    title: Text(txnTitle(t)),
                    subtitle: Text('${dateTimeLabel(t.occurredAt)} · ${money(left, currency: t.currency)} available'),
                    trailing: Text(
                      money(t.amountMinor, currency: t.currency),
                      style: context.text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    onTap: () => _confirm(context, ref, t),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _confirm(BuildContext context, WidgetRef ref, Transaction other) async {
    final payment = anchor.direction == TxnDirection.debit ? anchor : other;
    final received = anchor.direction == TxnDirection.debit ? other : anchor;
    final max = [payment.amountMinor - payment.linkedMinor, received.amountMinor - received.linkedMinor].reduce((a, b) => a < b ? a : b);
    final ctrl = TextEditingController(text: plainAmount(max, anchor.currency));
    final minor = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('How much of it counts?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${money(received.amountMinor, currency: received.currency)} received settles '
              '${money(payment.amountMinor, currency: payment.currency)} paid. This part is taken off your spending.',
              style: c.text.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.numberWithOptions(decimal: currencyDigits(anchor.currency) > 0),
              inputFormatters: [AmountInputFormatter(currency: anchor.currency)],
              decoration: InputDecoration(prefixText: '${currencySymbol(anchor.currency)} '),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(c, parseAmountInput(ctrl.text, currency: anchor.currency)),
            child: const Text('Link'),
          ),
        ],
      ),
    );
    if (minor == null || !context.mounted) return;
    final error = await ref
        .read(databaseProvider)
        .linkRepayment(paymentId: payment.id, receivedId: received.id, amountMinor: minor);
    if (!context.mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    Navigator.pop(context);
  }
}

/// Shown for transfers: the other leg, or a way to pair it.
class TransferPanel extends ConsumerWidget {
  const TransferPanel({super.key, required this.txn});
  final Transaction txn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!txn.isTransfer) return const SizedBox.shrink();
    final db = ref.read(databaseProvider);
    final partner = txn.transferPairId == null ? null : ref.watch(txnRowProvider(txn.transferPairId!)).value;
    final isOut = txn.direction == TxnDirection.debit;

    if (partner != null) {
      return AppCard(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(isOut ? PhosphorIconsBold.arrowDownLeft : PhosphorIconsBold.arrowUpRight),
          title: Text(isOut ? 'Received in another account' : 'Sent from another account'),
          subtitle: Text('${txnTitle(partner)} · ${dateTimeLabel(partner.occurredAt)}'),
          onTap: () {
            Navigator.pop(context);
            showTransactionSheet(context, partner.id);
          },
          trailing: TextButton(onPressed: () => db.unpairTransfer(txn.id), child: const Text('Unpair')),
        ),
      );
    }
    return OutlinedButton.icon(
      onPressed: () async {
        final list = await db.transferPairCandidates(txn);
        if (!context.mounted) return;
        if (list.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No matching transaction in another account within 7 days.')),
          );
          return;
        }
        final picked = await showModalBottomSheet<Transaction>(
          context: context,
          builder: (c) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text(isOut ? 'Where did it arrive?' : 'Where did it come from?', style: c.text.titleMedium),
                ),
                for (final t in list.take(20))
                  ListTile(
                    title: Text(txnTitle(t)),
                    subtitle: Text(dateTimeLabel(t.occurredAt)),
                    trailing: Text(money(t.amountMinor, currency: t.currency)),
                    onTap: () => Navigator.pop(c, t),
                  ),
              ],
            ),
          ),
        );
        if (picked != null) await db.pairTransfer(txn.id, picked.id);
      },
      icon: const Icon(PhosphorIconsBold.arrowsLeftRight, size: 18),
      label: const Text('Pair with the other side'),
    );
  }
}
