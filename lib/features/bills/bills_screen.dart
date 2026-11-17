import 'package:drift/drift.dart' show Value;
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
import '../activity/category_picker.dart';
import 'bill_schedule.dart';

/// Bills & subscriptions the user added by hand, with reminders.
class BillsScreen extends ConsumerWidget {
  const BillsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bills = ref.watch(billsProvider).value ?? const <Bill>[];
    final today = DateTime.now();
    final active = bills.where((b) => b.active).toList();
    final paused = bills.where((b) => !b.active).toList();
    final overdue = active.where((b) => daysUntil(b.nextDue, today) < 0).toList();
    final soon = active.where((b) => daysUntil(b.nextDue, today) >= 0 && daysUntil(b.nextDue, today) <= 7).toList();
    final later = active.where((b) => daysUntil(b.nextDue, today) > 7).toList();
    final next30 = active
        .where((b) => b.currency == Currencies.home && daysUntil(b.nextDue, today) <= 30)
        .fold<int>(0, (s, b) => s + b.amountMinor);
    final monthly = active
        .where((b) => b.currency == Currencies.home)
        .fold<double>(0, (s, b) => s + b.amountMinor * timesPerMonth(b.frequency));

    Widget group(String title, List<Bill> list) => list.isEmpty
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(title),
              for (final b in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _BillTile(bill: b, today: today),
                ),
              const SizedBox(height: 8),
            ],
          );

    return Scaffold(
      appBar: AppBar(title: const Text('Bills & subscriptions')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showBillEditor(context),
        icon: const Icon(PhosphorIconsBold.plus),
        label: const Text('Add'),
      ),
      body: bills.isEmpty
          ? EmptyState(
              icon: PhosphorIconsFill.bellRinging,
              title: 'No bills yet',
              message:
                  'Add rent, electricity, a Netflix plan, an insurance premium… and Pckt reminds you before they '
                  'are due — weekly, monthly or yearly.',
              action: FilledButton.icon(
                onPressed: () => showBillEditor(context),
                icon: const Icon(PhosphorIconsBold.plus),
                label: const Text('Add a bill'),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
              children: [
                AppCard(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Next 30 days', style: context.text.labelMedium),
                            const SizedBox(height: 4),
                            Text(money(next30), style: context.text.headlineSmall),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('≈ per month', style: context.text.labelMedium),
                          const SizedBox(height: 4),
                          Text(money(monthly.round()), style: context.text.titleMedium),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                group('Overdue', overdue),
                group('This week', soon),
                group('Later', later),
                group('Paused', paused),
              ],
            ),
    );
  }
}

class _BillTile extends ConsumerWidget {
  const _BillTile({required this.bill, required this.today});
  final Bill bill;
  final DateTime today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = bill;
    final db = ref.read(databaseProvider);
    final days = daysUntil(b.nextDue, today);
    final color = !b.active
        ? context.colors.onSurfaceVariant
        : days < 0
        ? Palette.coral
        : days <= 3
        ? Palette.amber
        : Palette.mint;

    Future<void> paid({required bool expense}) async {
      await db.markBillPaid(b, recordExpense: expense);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            b.frequency == 'once'
                ? '${b.name} marked as paid'
                : '${b.name} paid · next due ${dayLabel(advanceDue(b.nextDue, b.frequency))}',
          ),
        ),
      );
    }

    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      onTap: () => showBillEditor(context, bill: b),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(14)),
            child: Icon(b.isSubscription ? PhosphorIconsFill.repeat : PhosphorIconsFill.receipt, color: color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(b.name, style: context.text.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  b.active ? '${dueLabel(b.nextDue, today)} · ${dayLabel(b.nextDue)}' : 'Paused',
                  style: context.text.bodySmall?.copyWith(color: days < 0 && b.active ? Palette.coral : context.colors.onSurfaceVariant),
                ),
                Text(
                  [frequencyLabel(b.frequency), if (b.remindDaysBefore > 0) 'remind ${b.remindDaysBefore}d before'].join(' · '),
                  style: context.text.labelSmall?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (b.amountMinor > 0)
            Text(money(b.amountMinor, currency: b.currency), style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'paid':
                  await paid(expense: false);
                case 'paidExpense':
                  await paid(expense: true);
                case 'skip':
                  await db.skipBill(b);
                case 'toggle':
                  await db.setBillActive(b.id, !b.active);
                case 'delete':
                  await db.deleteBill(b.id);
              }
            },
            itemBuilder: (_) => [
              if (b.active) ...[
                const PopupMenuItem(value: 'paid', child: Text('Mark as paid')),
                if (b.amountMinor > 0) const PopupMenuItem(value: 'paidExpense', child: Text('Paid · add as expense')),
                if (b.frequency != 'once') const PopupMenuItem(value: 'skip', child: Text('Skip this one')),
              ],
              PopupMenuItem(value: 'toggle', child: Text(b.active ? 'Pause reminders' : 'Resume')),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> showBillEditor(BuildContext context, {Bill? bill, String? name, int? amountMinor, bool subscription = false}) =>
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _BillEditor(bill: bill, presetName: name, presetAmount: amountMinor, presetSubscription: subscription),
    );

class _BillEditor extends ConsumerStatefulWidget {
  const _BillEditor({this.bill, this.presetName, this.presetAmount, this.presetSubscription = false});
  final Bill? bill;
  final String? presetName;
  final int? presetAmount;
  final bool presetSubscription;

  @override
  ConsumerState<_BillEditor> createState() => _BillEditorState();
}

class _BillEditorState extends ConsumerState<_BillEditor> {
  late final _name = TextEditingController(text: widget.bill?.name ?? widget.presetName ?? '');
  late final _amount = TextEditingController(
    text: (widget.bill?.amountMinor ?? widget.presetAmount ?? 0) > 0
        ? plainAmount(widget.bill?.amountMinor ?? widget.presetAmount!, Currencies.home)
        : '',
  );
  late var _subscription = widget.bill?.isSubscription ?? widget.presetSubscription;
  late var _frequency = widget.bill?.frequency ?? 'monthly';
  late var _due = widget.bill?.nextDue ?? DateTime.now().add(const Duration(days: 7));
  late var _remind = widget.bill?.remindDaysBefore ?? 1;
  late int? _categoryId = widget.bill?.categoryId;

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final currency = widget.bill?.currency ?? Currencies.home;
    final minor = parseAmountInput(_amount.text, currency: currency) ?? 0;
    final ctrl = ref.read(databaseProvider);
    await ctrl.saveBill(
      BillsCompanion(
        id: widget.bill == null ? const Value.absent() : Value(widget.bill!.id),
        name: Value(name),
        amountMinor: Value(minor),
        currency: Value(currency),
        frequency: Value(_frequency),
        nextDue: Value(dateOnly(_due)),
        remindDaysBefore: Value(_remind),
        isSubscription: Value(_subscription),
        categoryId: Value(_categoryId),
        active: const Value(true),
      ),
    );
    // Reminders need the notification permission (Android 13+).
    await ref.read(billNotificationsProvider).requestPermission();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final currency = widget.bill?.currency ?? Currencies.home;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Bill'), icon: Icon(PhosphorIconsBold.receipt)),
                ButtonSegment(value: true, label: Text('Subscription'), icon: Icon(PhosphorIconsBold.repeat)),
              ],
              selected: {_subscription},
              onSelectionChanged: (s) => setState(() => _subscription = s.first),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              autofocus: widget.bill == null && widget.presetName == null,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                hintText: _subscription ? 'Netflix, Spotify, gym…' : 'Rent, electricity, credit card…',
                prefixIcon: const Icon(PhosphorIconsRegular.tag),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amount,
              keyboardType: TextInputType.numberWithOptions(decimal: currencyDigits(currency) > 0),
              inputFormatters: [AmountInputFormatter(currency: currency)],
              decoration: InputDecoration(
                labelText: 'Amount (optional)',
                prefixText: '${currencySymbol(currency)} ',
              ),
            ),
            const SizedBox(height: 16),
            Text('Repeats', style: context.text.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final f in billFrequencies)
                  ChoiceChip(
                    label: Text(frequencyLabel(f)),
                    selected: _frequency == f,
                    onSelected: (_) => setState(() => _frequency = f),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: const Icon(PhosphorIconsRegular.calendarBlank),
              title: Text(_frequency == 'once' ? 'Due on ${dayLabel(_due)}' : 'Next due ${dayLabel(_due)}'),
              onTap: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: _due,
                  firstDate: DateTime.now().subtract(const Duration(days: 365)),
                  lastDate: DateTime.now().add(const Duration(days: 365 * 10)),
                );
                if (d != null) setState(() => _due = d);
              },
            ),
            Text('Remind me', style: context.text.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final d in const [0, 1, 2, 3, 7])
                  ChoiceChip(
                    label: Text(d == 0 ? 'On the day' : d == 1 ? '1 day before' : '$d days before'),
                    selected: _remind == d,
                    onSelected: (_) => setState(() => _remind = d),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 2),
              child: Text(
                'You also get a reminder on the due date, around 9 am.',
                style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ),
            const SectionHeader('Category (optional)'),
            CategoryPicker(selectedId: _categoryId, income: false, onSelected: (c) => setState(() => _categoryId = c.id)),
            const SizedBox(height: 20),
            ListenableBuilder(
              listenable: _name,
              builder: (_, _) => FilledButton(
                onPressed: _name.text.trim().isEmpty ? null : _save,
                child: Text(widget.bill == null ? 'Save & remind me' : 'Save changes'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
