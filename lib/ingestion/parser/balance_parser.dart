import '../../core/currency.dart';
import 'parsed_txn.dart';
import 'senders.dart';
import 'text_utils.dart';

/// An account balance stated by a message ("Avl Bal Rs.12,345.67").
class ParsedBalance {
  const ParsedBalance({required this.minor, required this.currency, this.accountHint, this.institution});
  final int minor;
  final String currency;

  /// Last digits of the account the message names, if it names one.
  final String? accountHint;
  final String? institution;
}

/// Reads the balance out of bank alerts — both transaction alerts that end
/// "Avl Bal: Rs 5,000.00" and balance-enquiry replies. Credit-card "available
/// limit" figures are not balances and are skipped.
abstract final class BalanceParser {
  static final _otp = RegExp(r'\b(otp|one[- ]time password|verification code|passcode)\b');

  static const _num = r'(\d[\d,]*(?:\.\d{1,3})?)';
  static const _cur = r'(?:rs\.?|inr|₹)?';

  static final _qualified = RegExp(
    r'(?:avl|avail|available|ledger|clear|closing|current|total|net|updated|a/c)\.?\s*bal(?:ance)?\b\.?\s*'
    r'(?:is|of|:|-|=|as on [^\d]{0,20}|(?:in|of|for) (?:your )?(?:a/c|account|acct)[^\d]{0,12}\d{3,6}\s*(?:is|of|:|-|=)?)?\s*:?\s*-?\s*'
    '$_cur\\s*$_num',
  );
  static final _plain = RegExp(r'\bbal(?:ance)?\s*(?:is|of|:|-|=)\s*(?:rs\.?|inr|₹)\s*' + _num);
  static final _acct = RegExp(
    r'(?:a/?c|acct|account|card|ac)\s*(?:no\.?|number)?\s*(?:ending(?:\s*(?:with|in))?)?\s*[:\-]?\s*'
    r'(?:[x*.#]+\s*)?(\d{3,6})\b',
  );
  static final _acctXX = RegExp(r'\b[x*]{2,}(\d{3,6})\b');

  /// The balance [input] states, or null.
  static ParsedBalance? parse(RawInput input, {String home = 'INR'}) {
    final sender = Senders.parse(input.sender);
    if (sender.isPhoneNumber || sender.isPromotional) return null;
    final lower = normalizeSpace(input.body).toLowerCase();
    if (_otp.hasMatch(lower)) return null;
    final m = _qualified.firstMatch(lower) ?? _plain.firstMatch(lower);
    if (m == null) return null;
    final raw = m.group(1)!.replaceAll(',', '');
    final digits = currencyDigits(home);
    final parts = raw.split('.');
    final whole = int.tryParse(parts[0]);
    if (whole == null) return null;
    var frac = parts.length > 1 ? parts[1] : '';
    frac = frac.length > digits ? frac.substring(0, digits) : frac.padRight(digits, '0');
    var minor = whole;
    for (var i = 0; i < digits; i++) {
      minor *= 10;
    }
    minor += digits == 0 ? 0 : (int.tryParse(frac) ?? 0);
    final hint = (_acct.firstMatch(lower) ?? _acctXX.firstMatch(lower))?.group(1);
    return ParsedBalance(minor: minor, currency: home, accountHint: hint, institution: sender.institution);
  }
}
