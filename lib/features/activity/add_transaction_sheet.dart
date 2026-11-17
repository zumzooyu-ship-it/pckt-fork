import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/icons.dart';

import '../../core/format.dart';
import '../../core/theme/palette.dart';
import '../../data/db/database.dart';
import '../../data/db/extras.dart';
import '../settings/manage_widgets.dart' show accountLabel;
import '../../providers.dart';
import '../../ui/amount_field.dart';
import '../../ui/currency_picker.dart';
import '../../ui/widgets.dart';
import 'category_picker.dart';

Future<void> showAddTransactionSheet(BuildContext context) => showModalBottomSheet(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => const _AddSheet(),
);

class _AddSheet extends ConsumerStatefulWidget {
  const _AddSheet();

  @override
  ConsumerState<_AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends ConsumerState<_AddSheet> {
  final _amount = TextEditingController();
  final _merchant = TextEditingController();
  final _converted = TextEditingController();
  var _currency = Currencies.home;
  var _direction = TxnDirection.debit;
  int? _categoryId;
  var _at = DateTime.now();
  var _transfer = false;
  int? _fromId;
  int? _toId;
  final _note = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    _converted.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final minor = parseAmountInput(_amount.text, currency: _currency);
    if (minor == null || minor <= 0) return;
    if (_transfer) {
      if (_fromId == null || _toId == null || _fromId == _toId) return;
      await ref
          .read(databaseProvider)
          .addTransfer(
            fromId: _fromId!,
            toId: _toId!,
            amountMinor: minor,
            at: _at,
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
          );
      if (mounted) Navigator.pop(context);
      return;
    }
    final converted = _currency == Currencies.home
        ? null
        : parseAmountInput(_converted.text, currency: Currencies.home);
    await ref
        .read(databaseProvider)
        .addManual(
          amountMinor: minor,
          currency: _currency,
          convertedMinor: converted != null && converted > 0 ? converted : null,
          direction: _direction,
          at: _at,
          merchant: _merchant.text.trim().isEmpty ? null : _merchant.text.trim(),
          categoryId: _categoryId,
        );
    if (mounted) Navigator.pop(context);
  }

  List<Widget> _transferFields(BuildContext context) {
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    if (accounts.length < 2) {
      return [
        const SizedBox(height: 12),
        AppCard(
          color: Palette.amber.withValues(alpha: 0.12),
          padding: const EdgeInsets.all(14),
          child: const Text(
            'A transfer needs two accounts. Add the other one in Settings → Accounts '
            '(bank accounts also appear on their own once a bank SMS is read).',
          ),
        ),
      ];
    }
    DropdownButtonFormField<int> picker(String label, int? value, ValueChanged<int?> onChanged) =>
        DropdownButtonFormField<int>(
          initialValue: value,
          isExpanded: true,
          decoration: InputDecoration(labelText: label, prefixIcon: const Icon(PhosphorIconsRegular.bank)),
          items: [for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(accountLabel(a), overflow: TextOverflow.ellipsis))],
          onChanged: onChanged,
        );
    return [
      const SizedBox(height: 12),
      picker('From account', _fromId, (v) => setState(() => _fromId = v)),
      const SizedBox(height: 12),
      picker('To account', _toId, (v) => setState(() => _toId = v)),
      if (_fromId != null && _fromId == _toId)
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 4),
          child: Text('Pick two different accounts.', style: context.text.bodySmall?.copyWith(color: Palette.coral)),
        ),
      const SizedBox(height: 12),
      TextField(
        controller: _note,
        decoration: const InputDecoration(hintText: 'Note (optional)', prefixIcon: Icon(PhosphorIconsRegular.notePencil)),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final color = _direction == TxnDirection.credit ? Palette.income : context.colors.onSurface;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Expense'), icon: Icon(PhosphorIconsBold.arrowUpRight)),
                ButtonSegment(value: 1, label: Text('Income'), icon: Icon(PhosphorIconsBold.arrowDownLeft)),
                ButtonSegment(value: 2, label: Text('Transfer'), icon: Icon(PhosphorIconsBold.arrowsClockwise)),
              ],
              selected: {_transfer ? 2 : (_direction == TxnDirection.credit ? 1 : 0)},
              onSelectionChanged: (s) => setState(() {
                _transfer = s.first == 2;
                if (!_transfer) _direction = s.first == 1 ? TxnDirection.credit : TxnDirection.debit;
                if (_transfer && _currency != Currencies.home) {
                  _currency = Currencies.home;
                  _amount.clear();
                }
                _categoryId = null;
              }),
            ),
            const SizedBox(height: 20),
            AmountField(
              controller: _amount,
              autofocus: true,
              color: color,
              currency: _currency,
              onCurrencyTap: () async {
                final c = await showCurrencyPicker(context, selected: _currency);
                if (c == null || c == _currency) return;
                setState(() {
                  _currency = c;
                  _amount.clear();
                  _converted.clear();
                });
              },
            ),
            if (_currency != Currencies.home) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _converted,
                keyboardType: TextInputType.numberWithOptions(decimal: currencyDigits(Currencies.home) > 0),
                inputFormatters: [AmountInputFormatter(currency: Currencies.home)],
                decoration: InputDecoration(
                  labelText: 'In ${Currencies.home} (optional)',
                  helperText: 'Without it, this stays out of your totals until you add it.',
                  prefixText: '${currencySymbol(Currencies.home)} ',
                ),
              ),
            ],
            if (_transfer) ..._transferFields(context),
            if (!_transfer) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _merchant,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                hintText: _direction == TxnDirection.debit ? 'Where did you spend?' : 'From whom?',
                prefixIcon: const Icon(PhosphorIconsRegular.storefront),
              ),
            ),
            ],
            const SizedBox(height: 12),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: const Icon(PhosphorIconsRegular.calendarBlank),
              title: Text(dateTimeLabel(_at)),
              onTap: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: _at,
                  firstDate: DateTime(2015),
                  lastDate: DateTime.now(),
                );
                if (d != null) setState(() => _at = DateTime(d.year, d.month, d.day, _at.hour, _at.minute));
              },
            ),
            if (!_transfer) ...[
              const SectionHeader('Category'),
              CategoryPicker(
                selectedId: _categoryId,
                income: _direction == TxnDirection.credit,
                onSelected: (c) => setState(() => _categoryId = c.id),
              ),
            ],
            const SizedBox(height: 20),
            ListenableBuilder(
              listenable: _amount,
              builder: (_, _) => FilledButton(
                onPressed:
                    (parseAmountInput(_amount.text, currency: _currency) ?? 0) > 0 &&
                        (!_transfer || (_fromId != null && _toId != null && _fromId != _toId))
                    ? _save
                    : null,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
