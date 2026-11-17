import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme/icons.dart';
import '../../core/theme/palette.dart';
import '../../data/db/database.dart';
import '../../data/db/extras.dart';
import '../../ingestion/parser/text_utils.dart';
import '../../ingestion/templates/template_engine.dart';
import '../../providers.dart';
import '../../providers_extra.dart';
import '../../ui/widgets.dart';

/// Messages the built-in parser skipped that might still be transactions.
final missedMessagesProvider = StreamProvider<List<RawMessage>>((ref) {
  return ref.watch(databaseProvider).watchRawMessages(SourceKind.sms, {ParseStatus.ignored, ParseStatus.pendingLlm}).map((
    list,
  ) {
    const looksLikeTxn = {
      'No amount',
      'Not a transaction',
      'Could not read amount',
      'Could not tell debit from credit',
      'Balance alert',
      'Statement / bill',
      'Promotional',
    };
    return [
      for (final m in list)
        if ((m.parseStatus == ParseStatus.pendingLlm || looksLikeTxn.contains(m.ignoreReason)) &&
            RegExp(r'\d').hasMatch(m.body) &&
            !RegExp(r'\botp\b', caseSensitive: false).hasMatch(m.body))
          m,
    ].take(25).toList();
  });
});

/// Opens the "Teach Pckt" editor for [message] (or a blank paste screen).
Future<void> openTemplateEditor(BuildContext context, {RawMessage? message, ParserTemplate? existing}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => TemplateEditorScreen(
          sender: existing?.sampleSender ?? message?.sender,
          body: existing?.sampleBody ?? message?.body,
          existing: existing,
        ),
      ),
    );

class TemplatesScreen extends ConsumerWidget {
  const TemplatesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templates = ref.watch(templatesProvider).value ?? const <ParserTemplate>[];
    final missed = ref.watch(missedMessagesProvider).value ?? const <RawMessage>[];
    final db = ref.read(databaseProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Message templates')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => openTemplateEditor(context),
        icon: const Icon(PhosphorIconsBold.plus),
        label: const Text('Paste a message'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 12),
            child: Text(
              'Did Pckt miss a bank message? Pick it below (or paste it), tap the amount and a few other words, and '
              'Pckt will read every message that looks like it, including the old ones.',
              style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ),
          if (missed.isNotEmpty) ...[
            const SectionHeader('Possibly missed'),
            for (final m in missed.take(8))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: AppCard(
                  padding: const EdgeInsets.all(14),
                  onTap: () => openTemplateEditor(context, message: m),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(m.sender, style: context.text.labelLarge),
                            const SizedBox(height: 4),
                            Text(
                              m.body,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: context.text.bodySmall?.copyWith(height: 1.4),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      const FilledButton.tonal(onPressed: null, child: Text('Teach')),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
          ],
          SectionHeader('Your templates (${templates.length})'),
          if (templates.isEmpty)
            const EmptyState(
              icon: PhosphorIconsFill.magicWand,
              title: 'No templates yet',
              message: 'Teach Pckt a message format once and it reads all similar messages from then on.',
            ),
          for (final t in templates)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Dismissible(
                key: ValueKey('tpl-${t.id}'),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  decoration: BoxDecoration(color: Palette.coral, borderRadius: BorderRadius.circular(20)),
                  child: const Icon(PhosphorIconsBold.trash, color: Colors.white),
                ),
                confirmDismiss: (_) async =>
                    await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: Text('Delete "${t.name}"?'),
                        content: const Text('Transactions already created from it are kept.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
                        ],
                      ),
                    ) ??
                    false,
                onDismissed: (_) => db.deleteTemplate(t.id),
                child: AppCard(
                  padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                  onTap: () => openTemplateEditor(context, existing: t),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.name, style: context.text.titleSmall),
                            const SizedBox(height: 4),
                            Text(
                              t.sampleBody,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              children: [
                                InfoPill(icon: PhosphorIconsBold.chatText, label: t.senderPattern ?? 'Any sender'),
                                InfoPill(
                                  icon: PhosphorIconsBold.checkCircle,
                                  label: '${t.hits} read',
                                  color: t.hits > 0 ? Palette.mint : null,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Switch(value: t.enabled, onChanged: (v) => db.setTemplateEnabled(t.id, v)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

enum _Field { amount, merchant, account, reference }

extension on _Field {
  String get label => switch (this) {
    _Field.amount => 'Amount',
    _Field.merchant => 'Shop / person',
    _Field.account => 'Account digits',
    _Field.reference => 'Reference no.',
  };
  Color get color => switch (this) {
    _Field.amount => Palette.mint,
    _Field.merchant => Palette.violet,
    _Field.account => Palette.amber,
    _Field.reference => Palette.coral,
  };
  bool get multiWord => this == _Field.merchant;
}

/// The "Teach Pckt" editor: shows one message as tappable words; the user
/// picks which word is the amount, the shop, the account…
class TemplateEditorScreen extends ConsumerStatefulWidget {
  const TemplateEditorScreen({super.key, this.sender, this.body, this.existing});

  final String? sender;
  final String? body;
  final ParserTemplate? existing;

  @override
  ConsumerState<TemplateEditorScreen> createState() => _TemplateEditorState();
}

class _TemplateEditorState extends ConsumerState<TemplateEditorScreen> {
  late final _bodyCtrl = TextEditingController(text: widget.body ?? '');
  late final _senderCtrl = TextEditingController(text: widget.sender ?? '');
  late final _nameCtrl = TextEditingController(text: widget.existing?.name ?? '');
  var _direction = TxnDirection.debit;
  var _transfer = false;
  var _limitSender = true;
  var _active = _Field.amount;
  final _sel = <_Field, (int, int)>{};
  var _saving = false;

  String get _body => normalizeSpace(_bodyCtrl.text);
  List<BodyToken> get _tokens => tokenizeBody(_body);

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    if (ex != null) {
      final spec = TemplateSpec.decode(ex.specJson);
      if (spec != null) {
        _direction = spec.direction;
        _transfer = spec.transfer;
      }
      _limitSender = ex.senderPattern != null;
      _suggest(keepDirection: true);
    } else if (widget.body != null) {
      _suggest();
    }
  }

  @override
  void dispose() {
    _bodyCtrl.dispose();
    _senderCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  (int, int)? _tokenRange(Sel? s) {
    if (s == null) return null;
    final t = _tokens;
    final hit = [for (var i = 0; i < t.length; i++) if (t[i].start < s.end && t[i].end > s.start) i];
    return hit.isEmpty ? null : (hit.first, hit.last);
  }

  void _suggest({bool keepDirection = false}) {
    final s = TemplateEngine.suggest(_body);
    _sel.clear();
    for (final (f, sel) in [(_Field.amount, s.amount), (_Field.account, s.account), (_Field.reference, s.reference)]) {
      final r = _tokenRange(sel);
      if (r != null) _sel[f] = r;
    }
    if (!keepDirection) _direction = s.direction;
    // Re-open an existing template: show what it reads from its own sample.
    final ex = widget.existing;
    if (ex != null) _active = _Field.merchant;
  }

  Sel? _selOf(_Field f) {
    final r = _sel[f];
    if (r == null) return null;
    final t = _tokens;
    if (r.$2 >= t.length) return null;
    return Sel(t[r.$1].start, t[r.$2].end);
  }

  void _tap(int i) {
    setState(() {
      for (final e in _sel.entries.toList()) {
        if (e.key != _active && i >= e.value.$1 && i <= e.value.$2) _sel.remove(e.key);
      }
      final cur = _sel[_active];
      if (!_active.multiWord || cur == null) {
        _sel[_active] = (i, i);
      } else if (i >= cur.$1 && i <= cur.$2) {
        _sel.remove(_active);
      } else {
        _sel[_active] = (i < cur.$1 ? i : cur.$1, i > cur.$2 ? i : cur.$2);
      }
    });
  }

  TemplateSpec? _spec() {
    final amount = _selOf(_Field.amount);
    if (amount == null) return null;
    return TemplateEngine.build(
      _body,
      direction: _direction,
      amount: amount,
      merchant: _selOf(_Field.merchant),
      account: _selOf(_Field.account),
      reference: _selOf(_Field.reference),
      transfer: _transfer,
    );
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (d?.text == null) return;
    setState(() {
      _bodyCtrl.text = d!.text!;
      _suggest();
    });
  }

  Future<void> _save() async {
    final spec = _spec();
    if (spec == null || _saving) return;
    setState(() => _saving = true);
    final db = ref.read(databaseProvider);
    final sender = _senderCtrl.text.trim();
    final header = sender.isEmpty ? null : TemplateEngine.headerOf(sender);
    final name = _nameCtrl.text.trim().isEmpty
        ? '${header ?? 'Custom'} ${_transfer ? 'transfer' : _direction == TxnDirection.credit ? 'credit' : 'debit'}'
        : _nameCtrl.text.trim();
    final ex = widget.existing;
    final id = await db.saveTemplate(
      ParserTemplatesCompanion(
        id: ex == null ? const Value.absent() : Value(ex.id),
        name: Value(name),
        senderPattern: Value(_limitSender ? header : null),
        specJson: Value(spec.encode()),
        sampleBody: Value(_body),
        sampleSender: Value(sender.isEmpty ? null : sender),
        enabled: const Value(true),
      ),
    );
    final saved = (await db.enabledTemplates()).where((t) => t.id == id).firstOrNull;
    final added = saved == null ? 0 : await ref.read(ingestionProvider).applyTemplatesToStored(only: saved);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added > 0
              ? 'Template saved · $added earlier message${added == 1 ? '' : 's'} added as transactions'
              : 'Template saved · new messages like this will be read automatically',
        ),
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final body = _body;
    final tokens = _tokens;
    final spec = _spec();
    final reading = spec == null ? null : TemplateEngine.read(spec.encode(), body, currency: Currencies.home);
    final owner = <int, _Field>{};
    for (final e in _sel.entries) {
      for (var i = e.value.$1; i <= e.value.$2; i++) {
        owner[i] = e.key;
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'Teach Pckt' : 'Edit template'),
        actions: [
          TextButton(onPressed: spec == null || _saving ? null : _save, child: const Text('Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
        children: [
          if (widget.body == null) ...[
            TextField(
              controller: _bodyCtrl,
              minLines: 3,
              maxLines: 6,
              onChanged: (_) => setState(_suggest),
              decoration: InputDecoration(
                hintText: 'Paste the bank message here',
                suffixIcon: IconButton(onPressed: _paste, icon: const Icon(PhosphorIconsRegular.clipboardText)),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _senderCtrl,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                hintText: 'Sender, e.g. VM-HDFCBK (optional)',
                prefixIcon: Icon(PhosphorIconsRegular.chatText),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (body.isNotEmpty) ...[
            Text('1. What happened to your money?', style: context.text.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<TxnDirection>(
              segments: const [
                ButtonSegment(
                  value: TxnDirection.debit,
                  label: Text('Money out'),
                  icon: Icon(PhosphorIconsBold.arrowUpRight),
                ),
                ButtonSegment(
                  value: TxnDirection.credit,
                  label: Text('Money in'),
                  icon: Icon(PhosphorIconsBold.arrowDownLeft),
                ),
              ],
              selected: {_direction},
              onSelectionChanged: (s) => setState(() => _direction = s.first),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _transfer,
              onChanged: (v) => setState(() => _transfer = v),
              title: const Text('Transfer between my own accounts'),
            ),
            const SizedBox(height: 8),
            Text('2. Tap a label, then tap the words in the message', style: context.text.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final f in _Field.values)
                  ChoiceChip(
                    avatar: CircleAvatar(backgroundColor: f.color, radius: 6),
                    label: Text(f == _Field.amount ? '${f.label} *' : f.label),
                    selected: _active == f,
                    onSelected: (_) => setState(() => _active = f),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            AppCard(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 4,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < tokens.length; i++)
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _tap(i),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                        decoration: BoxDecoration(
                          color: owner[i]?.color.withValues(alpha: 0.28),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: owner[i]?.color ?? context.colors.outlineVariant.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Text(tokens[i].text, style: context.text.bodyMedium),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _active.multiWord
                  ? 'Tap the first and last word of the name.'
                  : _active == _Field.amount
                  ? 'Tap the number that is the amount of this payment (not the balance).'
                  : 'Optional. Tap the ${_active.label.toLowerCase()} in the message.',
              style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Text('3. Check', style: context.text.titleSmall),
            const SizedBox(height: 8),
            AppCard(
              color: (reading == null ? Palette.amber : Palette.mint).withValues(alpha: 0.12),
              padding: const EdgeInsets.all(14),
              child: reading == null
                  ? Text(
                      spec == null
                          ? 'Tap the amount in the message to start.'
                          : "This template can't read its own message. Try different words.",
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_transfer ? 'Transfer' : _direction == TxnDirection.credit ? 'Received' : 'Spent'} '
                          '${money(reading.amountMinor, forceDecimals: true)}',
                          style: context.text.titleMedium,
                        ),
                        if (reading.merchant != null) Text(_direction == TxnDirection.credit ? 'From ${reading.merchant}' : 'At ${reading.merchant}'),
                        if (reading.account != null) Text('Account ••${reading.account}'),
                        if (reading.reference != null) Text('Ref ${reading.reference}'),
                      ],
                    ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Template name (optional)',
                prefixIcon: Icon(PhosphorIconsRegular.tag),
              ),
            ),
            if (_senderCtrl.text.trim().isNotEmpty)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _limitSender,
                onChanged: (v) => setState(() => _limitSender = v),
                title: Text('Only for messages from ${TemplateEngine.headerOf(_senderCtrl.text)}'),
                subtitle: const Text('Turn off to also match other senders'),
              ),
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              onPressed: spec == null || reading == null || _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save template & scan old messages'),
            ),
          ],
        ],
      ),
    );
  }
}
