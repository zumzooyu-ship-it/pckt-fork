import 'dart:convert';
import 'dart:math' as math;

import '../../core/currency.dart';
import '../../data/db/database.dart';
import '../parser/parsed_txn.dart';
import '../parser/senders.dart';
import '../parser/text_utils.dart';

/// "Teach Pckt": user-made message templates.
///
/// A template is built from ONE sample message and the words the user tapped
/// in it (amount, merchant, account, reference). For each tapped field we keep
/// a little context from the sample: the few characters *before* the value
/// and the word *after* it. Matching another message means finding those same
/// anchors and reading whatever sits between them, so the template keeps
/// working when the amount, shop, date or reference change.
///
/// Numbers inside anchors match any number, spaces match any spacing, and
/// everything is case-insensitive.

/// A span of the (space-normalised) message body.
class Sel {
  const Sel(this.start, this.end);
  final int start;
  final int end;

  String of(String body) => body.substring(start, end);
}

class BodyToken {
  const BodyToken(this.start, this.end, this.text);
  final int start;
  final int end;
  final String text;
  bool get isNumber => RegExp(r'^\d[\d,]*(?:\.\d+)?$').hasMatch(text);
}

/// Splits a message into tappable pieces: numbers, words, single symbols.
List<BodyToken> tokenizeBody(String body) => [
  for (final m in RegExp(r"\d[\d,]*(?:\.\d+)?|[A-Za-z0-9][A-Za-z0-9@_\-/*&']*|\S").allMatches(body))
    BodyToken(m.start, m.end, m.group(0)!),
];

/// The context kept for one tapped field.
class TemplateField {
  const TemplateField({required this.before, required this.after});
  final String before;
  final String after;

  Map<String, Object?> toJson() => {'before': before, 'after': after};
  factory TemplateField.fromJson(Map<String, Object?> j) =>
      TemplateField(before: (j['before'] as String?) ?? '', after: (j['after'] as String?) ?? '');
}

class TemplateSpec {
  const TemplateSpec({
    required this.direction,
    required this.amount,
    this.merchant,
    this.account,
    this.reference,
    this.transfer = false,
  });

  final TxnDirection direction;
  final TemplateField amount;
  final TemplateField? merchant;
  final TemplateField? account;
  final TemplateField? reference;

  /// The message describes a move between the user's own accounts.
  final bool transfer;

  String encode() => jsonEncode({
    'direction': direction.name,
    'transfer': transfer,
    'amount': amount.toJson(),
    'merchant': merchant?.toJson(),
    'account': account?.toJson(),
    'reference': reference?.toJson(),
  });

  static TemplateSpec? decode(String json) {
    try {
      final j = (jsonDecode(json) as Map).cast<String, Object?>();
      TemplateField? f(String k) => j[k] == null ? null : TemplateField.fromJson((j[k]! as Map).cast());
      return TemplateSpec(
        direction: j['direction'] == 'credit' ? TxnDirection.credit : TxnDirection.debit,
        transfer: j['transfer'] == true,
        amount: f('amount')!,
        merchant: f('merchant'),
        account: f('account'),
        reference: f('reference'),
      );
    } catch (_) {
      return null;
    }
  }
}

/// What a template read out of a message.
class TemplateReading {
  const TemplateReading({required this.amountMinor, this.merchant, this.account, this.reference});
  final int amountMinor;
  final String? merchant;
  final String? account;
  final String? reference;
}

class _Compiled {
  _Compiled(this.spec)
    : amount = _build(spec.amount, _amountCapture),
      merchant = spec.merchant == null ? null : _build(spec.merchant!, _merchantCapture, lookahead: true),
      account = spec.account == null ? null : _build(spec.account!, _accountCapture),
      reference = spec.reference == null ? null : _build(spec.reference!, _refCapture);

  final TemplateSpec spec;
  final RegExp amount;
  final RegExp? merchant;
  final RegExp? account;
  final RegExp? reference;

  static const _amountCapture = r'(\d[\d,]*(?:\.\d+)?)';
  static const _merchantCapture = r'(.{1,60}?)';
  static const _accountCapture = r'(\d{3,8})';
  static const _refCapture = r'([A-Za-z0-9]{6,30})';

  static RegExp _build(TemplateField f, String capture, {bool lookahead = false}) {
    final before = f.before.isEmpty ? r'(?:^|\s)' : literalPattern(f.before);
    var tail = '';
    if (lookahead) {
      tail = f.after.isEmpty ? r'(?=\n|$)' : '(?=${literalPattern(f.after)})';
    }
    return RegExp('$before$capture$tail', caseSensitive: false);
  }
}

/// Anchor text as a regex: digits match any digits, whitespace any spacing.
String literalPattern(String s) {
  final b = StringBuffer();
  for (final m in RegExp(r'\d+|\s+|[^\d\s]+').allMatches(s)) {
    final t = m.group(0)!;
    if (RegExp(r'^\d').hasMatch(t)) {
      b.write(r'\d+');
    } else if (RegExp(r'^\s').hasMatch(t)) {
      b.write(r'\s+');
    } else {
      // Month names in dates ("12-Sep-25") change from message to message.
      var last = 0;
      for (final mm in _month.allMatches(t)) {
        b.write(RegExp.escape(t.substring(last, mm.start)));
        b.write(r'[A-Za-z]{3,9}');
        last = mm.end;
      }
      b.write(RegExp.escape(t.substring(last)));
    }
  }
  return b.toString();
}

final _month = RegExp(
  r'\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|'
  r'nov(?:ember)?|dec(?:ember)?)\b',
  caseSensitive: false,
);

abstract final class TemplateEngine {
  static final _cache = <String, _Compiled>{};

  static _Compiled? _compiled(String specJson) {
    final hit = _cache[specJson];
    if (hit != null) return hit;
    final spec = TemplateSpec.decode(specJson);
    if (spec == null) return null;
    try {
      return _cache[specJson] = _Compiled(spec);
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------- building

  static TemplateField _anchor(String body, Sel s, {required bool narrowAfter}) {
    // The last two words before the value: enough to find it again, few
    // enough not to include things (a shop name) that change per message.
    final lead = body.substring(0, s.start);
    final words = RegExp(r'\S+\s*').allMatches(lead).map((m) => m.group(0)!).toList();
    var before = words.length <= 2 ? lead : words.sublist(words.length - 2).join();
    if (before.length > 30) before = before.substring(before.length - 30);
    if (before.length == 30 && !lead.endsWith(before.trimLeft())) before = before.trimLeft();
    // Only the first word/symbol after the value: robust across variants.
    final rest = body.substring(s.end);
    final after = RegExp(r'^\s*[^\s\w]*\w*').firstMatch(rest)?.group(0) ?? '';
    return TemplateField(before: before, after: narrowAfter ? after : '');
  }

  /// Builds a template from the tapped spans of [body] (space-normalised).
  static TemplateSpec build(
    String body, {
    required TxnDirection direction,
    required Sel amount,
    Sel? merchant,
    Sel? account,
    Sel? reference,
    bool transfer = false,
  }) {
    Sel? digits(Sel? s) {
      if (s == null) return null;
      final run = RegExp(r'\d+').allMatches(s.of(body)).lastOrNull;
      return run == null ? null : Sel(s.start + run.start, s.start + run.end);
    }

    final acc = digits(account);
    return TemplateSpec(
      direction: direction,
      transfer: transfer,
      amount: _anchor(body, amount, narrowAfter: false),
      merchant: merchant == null ? null : _anchor(body, merchant, narrowAfter: true),
      account: acc == null ? null : _anchor(body, acc, narrowAfter: false),
      reference: reference == null ? null : _anchor(body, reference, narrowAfter: false),
    );
  }

  // ------------------------------------------------------------- reading

  /// Reads [body] with [spec]; null when the amount anchor isn't found.
  static TemplateReading? read(String specJson, String body, {String currency = 'INR'}) {
    final c = _compiled(specJson);
    if (c == null) return null;
    final text = normalizeSpace(body);
    final a = c.amount.firstMatch(text);
    if (a == null) return null;
    final minor = parseMinor(a.group(1)!, currency);
    if (minor == null || minor <= 0) return null;
    String? merchant = c.merchant?.firstMatch(text)?.group(1);
    merchant = merchant?.replaceAll(RegExp(r'[\s.,;:\-]+$'), '').trim();
    var account = c.account?.firstMatch(text)?.group(1);
    if (account != null && account.length > 4) account = account.substring(account.length - 4);
    return TemplateReading(
      amountMinor: minor,
      merchant: merchant == null || merchant.isEmpty ? null : merchant,
      account: account,
      reference: c.reference?.firstMatch(text)?.group(1),
    );
  }

  /// "1,234.50" → 123450 in [currency]'s minor units; null if unreadable.
  static int? parseMinor(String s, String currency) {
    final clean = s.replaceAll(',', '');
    final parts = clean.split('.');
    if (parts.length > 2 || parts[0].isEmpty) return null;
    final d = currencyDigits(currency);
    final whole = int.tryParse(parts[0]);
    if (whole == null) return null;
    var frac = parts.length == 2 ? parts[1] : '';
    frac = frac.length > d ? frac.substring(0, d) : frac.padRight(d, '0');
    final f = d == 0 ? 0 : int.tryParse(frac);
    if (f == null) return null;
    return whole * math.pow(10, d).toInt() + f;
  }

  /// True when [template] applies to a message from [sender].
  static bool senderMatches(String? pattern, String sender) {
    if (pattern == null || pattern.trim().isEmpty) return true;
    final want = pattern.trim().toUpperCase();
    return sender.trim().toUpperCase() == want || Senders.parse(sender).header == want;
  }

  /// Short sender header for display / matching (`VM-HDFCBK-S` → `HDFCBK`).
  static String headerOf(String sender) => Senders.parse(sender).header;

  /// Parses [input] with [t], or returns null when it doesn't apply.
  static Parsed? tryParse(ParserTemplate t, RawInput input, {String home = 'INR'}) {
    if (!senderMatches(t.senderPattern, input.sender)) return null;
    final r = read(t.specJson, input.body, currency: home);
    if (r == null) return null;
    final spec = _compiled(t.specJson)!.spec;
    final lower = input.body.toLowerCase();
    final mode = lower.contains('upi')
        ? PaymentMode.upi
        : RegExp(r'\bcard\b').hasMatch(lower)
        ? PaymentMode.card
        : lower.contains('neft')
        ? PaymentMode.neft
        : lower.contains('imps')
        ? PaymentMode.imps
        : lower.contains('rtgs')
        ? PaymentMode.rtgs
        : lower.contains('atm')
        ? PaymentMode.atm
        : PaymentMode.other;
    return Parsed(
      ParsedTxn(
        amountMinor: r.amountMinor,
        currency: home,
        direction: spec.direction,
        occurredAt: input.receivedAt,
        mode: mode,
        // The user taught this format, so trust it.
        confidence: 0.95,
        merchant: r.merchant,
        accountHint: r.account,
        reference: r.reference,
        institution: Senders.parse(input.sender).institution,
        transferHint: spec.transfer,
      ),
    );
  }

  // ---------------------------------------------------------- suggestions

  /// Best guesses for the editor so most messages need only a couple of taps.
  static ({TxnDirection direction, Sel? amount, Sel? account, Sel? reference}) suggest(String body) {
    final lower = body.toLowerCase();
    Sel? amount;
    for (final m in RegExp(r'(?:rs\.?|inr|₹)\s*(\d[\d,]*(?:\.\d+)?)', caseSensitive: false).allMatches(body)) {
      final ctx = lower.substring(math.max(0, m.start - 14), m.start);
      if (RegExp(r'bal|avl|limit|lmt').hasMatch(ctx)) continue;
      amount = Sel(m.end - m.group(1)!.length, m.end);
      break;
    }
    amount ??= () {
      final n = RegExp(r'\d[\d,]*(?:\.\d+)?').firstMatch(body);
      return n == null ? null : Sel(n.start, n.end);
    }();
    final acc = RegExp(r'(?:a/?c|acct|account|card)\s*(?:no\.?|number)?\s*(?:ending(?:\s*(?:with|in))?)?\W{0,6}?[x*]*\s*(\d{4})\b', caseSensitive: false).firstMatch(body);
    final ref = RegExp(r'(?:ref(?:erence)?|rrn|utr|txn)\D{0,12}(\d{8,})', caseSensitive: false).firstMatch(body);
    final credit = RegExp(r'credited|received|deposited|refund|reversed').hasMatch(lower);
    return (
      direction: credit ? TxnDirection.credit : TxnDirection.debit,
      amount: amount,
      account: acc == null ? null : Sel(acc.end - acc.group(1)!.length, acc.end),
      reference: ref == null ? null : Sel(ref.end - ref.group(1)!.length, ref.end),
    );
  }
}
