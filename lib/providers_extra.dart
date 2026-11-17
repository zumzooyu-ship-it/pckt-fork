import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/format.dart';
import 'core/notifications.dart';
import 'data/db/database.dart';
import 'data/db/extras.dart';
import 'features/bills/bill_schedule.dart';
import 'providers.dart';

/// Providers for the v5 features (templates, bills, links). Kept out of
/// `providers.dart` so that file stays close to upstream.

final templatesProvider = StreamProvider<List<ParserTemplate>>((ref) => ref.watch(databaseProvider).watchTemplates());

final billsProvider = StreamProvider<List<Bill>>((ref) => ref.watch(databaseProvider).watchBills());

final linkViewsProvider = StreamProvider.family<List<LinkView>, int>(
  (ref, id) => ref.watch(databaseProvider).watchLinkViews(id),
);

final txnRowProvider = StreamProvider.family<Transaction?, int>(
  (ref, id) => ref.watch(databaseProvider).watchTxnRow(id),
);

final billNotificationsProvider = Provider((ref) => LocalNotifications());

/// Keeps scheduled bill reminders in step with the bills: re-armed whenever
/// a bill changes and every time the app starts. Watch it once from the app.
class BillRemindersController extends Notifier<void> {
  Timer? _debounce;

  @override
  void build() {
    final sub = ref.read(databaseProvider).watchBills().listen((b) => _schedule(b));
    ref.onDispose(() {
      _debounce?.cancel();
      sub.cancel();
    });
  }

  void _schedule(List<Bill> bills) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () => _apply(bills));
  }

  Future<void> _apply(List<Bill> bills) async {
    final now = DateTime.now();
    final items = <({int id, String title, String body, DateTime at})>[];
    for (final b in bills.where((b) => b.active)) {
      final amount = b.amountMinor > 0 ? ' · ${money(b.amountMinor, currency: b.currency)}' : '';
      for (final m in reminderMoments(b.nextDue, b.remindDaysBefore, now)) {
        final days = daysUntil(b.nextDue, m.at);
        items.add((
          id: LocalNotifications.billIdBase + b.id * 2 + (m.early ? 0 : 1),
          title: b.isSubscription ? '${b.name} renews ${days == 0 ? 'today' : 'in $days day${days == 1 ? '' : 's'}'}' : '${b.name} is due ${days == 0 ? 'today' : 'in $days day${days == 1 ? '' : 's'}'}',
          body: '${frequencyLabel(b.frequency)}$amount',
          at: m.at,
        ));
      }
    }
    try {
      await ref.read(billNotificationsProvider).rescheduleBills(items);
    } catch (e) {
      debugPrint('Bill reminders: $e');
    }
  }
}

final billRemindersProvider = NotifierProvider<BillRemindersController, void>(BillRemindersController.new);

/// Total of the balances of active accounts held in the home currency.
({int total, int counted, int missing}) balanceTotals(List<Account> accounts) {
  var total = 0, counted = 0, missing = 0;
  for (final a in accounts.where((a) => !a.archived && a.kind != AccountKind.creditCard)) {
    if (a.balanceMinor != null && a.currency == Currencies.home) {
      total += a.balanceMinor!;
      counted++;
    } else if (a.balanceMinor == null) {
      missing++;
    }
  }
  return (total: total, counted: counted, missing: missing);
}
