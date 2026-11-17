import 'package:flutter_test/flutter_test.dart';
import 'package:pckt/data/db/tables.dart';
import 'package:pckt/features/bills/bill_schedule.dart';
import 'package:pckt/ingestion/parser/balance_parser.dart';
import 'package:pckt/ingestion/parser/parsed_txn.dart';
import 'package:pckt/ingestion/templates/template_engine.dart';

RawInput msg(String sender, String body) =>
    RawInput(source: SourceKind.sms, externalId: '1', sender: sender, body: body, receivedAt: DateTime(2026, 1, 1));

void main() {
  group('template engine', () {
    const sample = 'Dear Customer, INR 1,250.00 has been spent on your Xyz Card ending 4321 at PVR CINEMAS on 12-Sep-25. Ref 998877665544.';
    test('learns from one message and reads another', () {
      final s = TemplateEngine.suggest(sample);
      expect(s.amount!.of(sample), '1,250.00');
      expect(s.account!.of(sample), '4321');
      expect(s.reference!.of(sample), '998877665544');
      final mStart = sample.indexOf('PVR');
      final spec = TemplateEngine.build(
        sample,
        direction: s.direction,
        amount: s.amount!,
        merchant: Sel(mStart, mStart + 'PVR CINEMAS'.length),
        account: s.account,
        reference: s.reference,
      );
      final other =
          'Dear Customer, INR 99.50 has been spent on your Xyz Card ending 7788 at SWIGGY on 03-Oct-25. Ref 112233445566.';
      final r = TemplateEngine.read(spec.encode(), other)!;
      expect(r.amountMinor, 9950);
      expect(r.merchant, 'SWIGGY');
      expect(r.account, '7788');
      expect(r.reference, '112233445566');
      expect(TemplateEngine.read(spec.encode(), 'Your OTP is 123456'), isNull);
    });
    test('credit direction + sender filter', () {
      expect(TemplateEngine.senderMatches('HDFCBK', 'VM-HDFCBK-S'), isTrue);
      expect(TemplateEngine.senderMatches('HDFCBK', 'AX-ICICIT'), isFalse);
      expect(TemplateEngine.parseMinor('1,23,456.7', 'INR'), 12345670);
    });
  });

  group('balance parser', () {
    test('reads avl bal from a debit alert', () {
      final b = BalanceParser.parse(
        msg('VM-HDFCBK-S', 'Rs.500.00 debited from A/c XX1234 on 01-01-26 to VPA x@ybl. Avl Bal Rs.12,345.67'),
      )!;
      expect(b.minor, 1234567);
      expect(b.accountHint, '1234');
    });
    test('ignores credit card available limit and OTPs', () {
      expect(BalanceParser.parse(msg('VM-HDFCBK-S', 'Spent Rs.500 on card XX1234. Avl Lmt Rs.50,000')), isNull);
      expect(BalanceParser.parse(msg('VM-HDFCBK-S', 'OTP 123456 for txn. Avl Bal Rs.100')), isNull);
    });
    test('balance enquiry', () {
      final b = BalanceParser.parse(msg('AD-SBIINB', 'Available balance in A/c XX9876 is Rs.2,000.50 as on 01-Jan'))!;
      expect(b.minor, 200050);
      expect(b.accountHint, '9876');
    });
  });

  group('bill schedule', () {
    test('month end clamps', () {
      expect(advanceDue(DateTime(2026, 1, 31), 'monthly'), DateTime(2026, 2, 28));
      expect(advanceDue(DateTime(2026, 5, 10), 'weekly'), DateTime(2026, 5, 17));
      expect(advanceDue(DateTime(2026, 5, 10), 'yearly'), DateTime(2027, 5, 10));
    });
    test('reminders', () {
      final now = DateTime(2026, 5, 8, 10);
      final m = reminderMoments(DateTime(2026, 5, 10), 2, now);
      expect(m.length, 1); // the early one (8 May 9:00) has passed
      expect(m.single.early, isFalse);
      expect(dueLabel(DateTime(2026, 5, 9), DateTime(2026, 5, 10)), '1 day overdue');
    });
  });
}
