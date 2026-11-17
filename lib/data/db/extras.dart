import 'package:drift/drift.dart';

import '../../core/currency.dart';
import '../../features/bills/bill_schedule.dart';
import 'database.dart';

/// Database operations added in schema v5 (custom parser templates,
/// self-transfers, repayment links, account balances, bills). Kept apart from
/// `database.dart` so the original file stays easy to diff against upstream.
extension DbExtras on AppDatabase {
  // ===================================================== repayment links

  /// Re-derives `linked_minor` for [txnId] from its links.
  Future<void> recomputeLinked(int txnId) async {
    final row = await customSelect(
      'SELECT COALESCE(SUM(amount_minor), 0) AS s FROM txn_links WHERE payment_id = ? OR received_id = ?',
      variables: [Variable<int>(txnId), Variable<int>(txnId)],
    ).getSingle();
    final sum = row.read<int>('s');
    await (update(
      transactions,
    )..where((t) => t.id.equals(txnId))).write(TransactionsCompanion(linkedMinor: Value(sum)));
  }

  /// After a bulk delete (e.g. re-importing SMS): fix every `linked_minor`.
  Future<void> recomputeAllLinked() async {
    await customStatement(
      'UPDATE transactions SET linked_minor = COALESCE((SELECT SUM(amount_minor) FROM txn_links '
      'WHERE payment_id = transactions.id OR received_id = transactions.id), 0)',
    );
    await customStatement(
      'UPDATE transactions SET transfer_pair_id = NULL WHERE transfer_pair_id IS NOT NULL AND '
      'transfer_pair_id NOT IN (SELECT id FROM transactions)',
    );
  }

  Future<Transaction?> txnById(int id) => (select(transactions)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Links money received to a payment it settles (a friend's share of the
  /// movie tickets, a refund). Returns an error message, or null on success.
  Future<String?> linkRepayment({required int paymentId, required int receivedId, required int amountMinor}) =>
      transaction(() async {
        final p = await txnById(paymentId);
        final r = await txnById(receivedId);
        if (p == null || r == null) return 'That transaction no longer exists.';
        if (p.direction != TxnDirection.debit || r.direction != TxnDirection.credit) {
          return 'Link a payment with money received.';
        }
        if (p.currency != r.currency) return 'Both have to be in the same currency.';
        if (amountMinor <= 0) return 'Enter an amount.';
        final payFree = p.amountMinor - p.linkedMinor;
        final recFree = r.amountMinor - r.linkedMinor;
        if (amountMinor > payFree) {
          return 'Only ${plainAmount(payFree, p.currency)} of the payment is left to settle.';
        }
        if (amountMinor > recFree) {
          return 'Only ${plainAmount(recFree, r.currency)} of the received money is left to link.';
        }
        await into(
          txnLinks,
        ).insert(TxnLinksCompanion.insert(paymentId: paymentId, receivedId: receivedId, amountMinor: amountMinor));
        await recomputeLinked(paymentId);
        await recomputeLinked(receivedId);
        return null;
      });

  Future<void> removeLink(int linkId) => transaction(() async {
    final l = await (select(txnLinks)..where((x) => x.id.equals(linkId))).getSingleOrNull();
    if (l == null) return;
    await (delete(txnLinks)..where((x) => x.id.equals(linkId))).go();
    await recomputeLinked(l.paymentId);
    await recomputeLinked(l.receivedId);
  });

  /// Links on [txnId] (either side) paired with the transaction at the other end.
  Stream<List<LinkView>> watchLinkViews(int txnId) {
    final q = select(txnLinks)
      ..where((l) => l.paymentId.equals(txnId) | l.receivedId.equals(txnId))
      ..orderBy([(l) => OrderingTerm(expression: l.createdAt)]);
    return q.watch().asyncMap((links) async {
      final out = <LinkView>[];
      for (final l in links) {
        final other = await txnById(l.paymentId == txnId ? l.receivedId : l.paymentId);
        if (other != null) out.add(LinkView(l, other));
      }
      return out;
    });
  }

  /// Opposite-direction transactions that could be linked to [anchor]: same
  /// currency, something still unsettled, within 90 days, closest in time first.
  Future<List<Transaction>> linkCandidates(Transaction anchor) async {
    final opposite = anchor.direction == TxnDirection.debit ? TxnDirection.credit : TxnDirection.debit;
    const span = Duration(days: 90);
    final rows =
        await (select(transactions)..where(
              (t) =>
                  t.direction.equalsValue(opposite) &
                  t.currency.equals(anchor.currency) &
                  t.isTransfer.equals(false) &
                  t.id.equals(anchor.id).not() &
                  t.occurredAt.isBetweenValues(anchor.occurredAt.subtract(span), anchor.occurredAt.add(span)),
            ))
            .get();
    final free = rows.where((t) => t.amountMinor - t.linkedMinor > 0).toList()
      ..sort(
        (a, b) => a.occurredAt
            .difference(anchor.occurredAt)
            .abs()
            .compareTo(b.occurredAt.difference(anchor.occurredAt).abs()),
      );
    return free.take(80).toList();
  }

  // ========================================================== transfers

  Future<int?> _transfersCategory() async {
    final c = await (select(categories)..where((c) => c.seedName.equals('Transfers'))).getSingleOrNull();
    return c?.id;
  }

  /// A transfer between two of the user's own accounts: a debit on [fromId]
  /// and a credit on [toId], linked as a pair and kept out of spend/income.
  /// Returns the debit's id.
  Future<int> addTransfer({
    required int fromId,
    required int toId,
    required int amountMinor,
    required DateTime at,
    String? note,
  }) => transaction(() async {
    final from = await (select(accounts)..where((a) => a.id.equals(fromId))).getSingle();
    final to = await (select(accounts)..where((a) => a.id.equals(toId))).getSingle();
    final cat = await _transfersCategory();

    Future<int> leg(TxnDirection d, Account acc, String merchant) async {
      final id = await into(transactions).insert(
        TransactionsCompanion.insert(
          amountMinor: amountMinor,
          currency: Value(from.currency),
          direction: d,
          occurredAt: at,
          merchant: Value(merchant),
          note: Value(note),
          categoryId: Value(cat),
          accountId: Value(acc.id),
          mode: PaymentMode.other,
          status: TxnStatus.confirmed,
          isTransfer: const Value(true),
          categoryLocked: const Value(true),
        ),
      );
      await into(rawMessages).insert(
        RawMessagesCompanion.insert(
          source: SourceKind.manual,
          externalId: 'manual-$id',
          sender: 'You',
          body: 'Added manually (transfer)',
          receivedAt: DateTime.now(),
          parseStatus: ParseStatus.parsed,
          transactionId: Value(id),
        ),
      );
      return id;
    }

    final debitId = await leg(TxnDirection.debit, from, 'Transfer to ${to.name}');
    final creditId = await leg(TxnDirection.credit, to, 'Transfer from ${from.name}');
    await _pair(debitId, creditId);
    return debitId;
  });

  Future<void> _pair(int a, int b) async {
    await (update(transactions)..where((t) => t.id.equals(a))).write(
      TransactionsCompanion(transferPairId: Value(b), isTransfer: const Value(true)),
    );
    await (update(transactions)..where((t) => t.id.equals(b))).write(
      TransactionsCompanion(transferPairId: Value(a), isTransfer: const Value(true)),
    );
  }

  /// Marks two existing transactions (a debit and a credit) as the two legs
  /// of one self-transfer.
  Future<void> pairTransfer(int a, int b) => transaction(() => _pair(a, b));

  /// Detaches a transfer's legs from each other (they stay transfers).
  Future<void> unpairTransfer(int id) => (update(transactions)..where((t) => t.id.equals(id) | t.transferPairId.equals(id)))
      .write(const TransactionsCompanion(transferPairId: Value(null)));

  /// Unpaired transactions that look like the other leg of [t].
  Future<List<Transaction>> transferPairCandidates(Transaction t) async {
    final opposite = t.direction == TxnDirection.debit ? TxnDirection.credit : TxnDirection.debit;
    final rows =
        await (select(transactions)..where(
              (x) =>
                  x.direction.equalsValue(opposite) &
                  x.amountMinor.equals(t.amountMinor) &
                  x.currency.equals(t.currency) &
                  x.transferPairId.isNull() &
                  x.id.equals(t.id).not() &
                  x.occurredAt.isBetweenValues(
                    t.occurredAt.subtract(const Duration(days: 7)),
                    t.occurredAt.add(const Duration(days: 7)),
                  ),
            ))
            .get();
    return rows..sort(
      (a, b) => a.occurredAt.difference(t.occurredAt).abs().compareTo(b.occurredAt.difference(t.occurredAt).abs()),
    );
  }

  Stream<Transaction?> watchTxnRow(int id) =>
      (select(transactions)..where((t) => t.id.equals(id))).watchSingleOrNull();

  // ============================================================ balances

  /// Stores [minor] as the account's balance as of [at] — unless a newer
  /// balance is already stored (messages arrive oldest-first, but a re-scan
  /// must never move a balance back in time).
  Future<void> applyBalance(int accountId, int minor, DateTime at, {bool manual = false}) async {
    final a = await (select(accounts)..where((x) => x.id.equals(accountId))).getSingleOrNull();
    if (a == null) return;
    if (!manual && a.balanceAt != null && at.isBefore(a.balanceAt!)) return;
    await (update(accounts)..where((x) => x.id.equals(accountId))).write(
      AccountsCompanion(balanceMinor: Value(minor), balanceAt: Value(at), balanceManual: Value(manual)),
    );
  }

  Future<void> clearBalance(int accountId) => (update(accounts)..where((x) => x.id.equals(accountId))).write(
    const AccountsCompanion(balanceMinor: Value(null), balanceAt: Value(null), balanceManual: Value(false)),
  );

  // ========================================================== templates

  Stream<List<ParserTemplate>> watchTemplates() =>
      (select(parserTemplates)..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).watch();

  Future<List<ParserTemplate>> enabledTemplates() =>
      (select(parserTemplates)
            ..where((t) => t.enabled.equals(true))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  Future<int> saveTemplate(ParserTemplatesCompanion t) => into(parserTemplates).insertOnConflictUpdate(t);

  Future<void> deleteTemplate(int id) => (delete(parserTemplates)..where((t) => t.id.equals(id))).go();

  Future<void> setTemplateEnabled(int id, bool on) => (update(
    parserTemplates,
  )..where((t) => t.id.equals(id))).write(ParserTemplatesCompanion(enabled: Value(on)));

  Future<void> addTemplateHits(Map<int, int> hits) async {
    for (final e in hits.entries) {
      await customUpdate(
        'UPDATE parser_templates SET hits = hits + ? WHERE id = ?',
        variables: [Variable<int>(e.value), Variable<int>(e.key)],
        updates: {parserTemplates},
      );
    }
  }

  // =============================================================== bills

  Stream<List<Bill>> watchBills() => (select(bills)
        ..orderBy([
          (b) => OrderingTerm(expression: b.active, mode: OrderingMode.desc),
          (b) => OrderingTerm(expression: b.nextDue),
        ]))
      .watch();

  Future<List<Bill>> allBills() => select(bills).get();

  Future<int> saveBill(BillsCompanion b) => into(bills).insertOnConflictUpdate(b);

  Future<void> deleteBill(int id) => (delete(bills)..where((b) => b.id.equals(id))).go();

  Future<void> setBillActive(int id, bool on) =>
      (update(bills)..where((b) => b.id.equals(id))).write(BillsCompanion(active: Value(on)));

  /// Marks the current cycle paid: moves [Bill.nextDue] on one period (a
  /// one-off bill is switched off), and optionally records the expense.
  Future<void> markBillPaid(Bill b, {bool recordExpense = false, DateTime? paidOn}) => transaction(() async {
    final paid = paidOn ?? DateTime.now();
    if (recordExpense && b.amountMinor > 0) {
      await addManual(
        amountMinor: b.amountMinor,
        currency: b.currency,
        direction: TxnDirection.debit,
        at: paid,
        merchant: b.name,
        categoryId: b.categoryId,
        accountId: b.accountId,
        note: b.isSubscription ? 'Subscription' : 'Bill',
      );
    }
    await (update(bills)..where((x) => x.id.equals(b.id))).write(
      BillsCompanion(
        lastPaidAt: Value(paid),
        nextDue: Value(advanceDue(b.nextDue, b.frequency)),
        active: Value(b.frequency != 'once'),
      ),
    );
  });

  /// Skips the current cycle without paying.
  Future<void> skipBill(Bill b) => (update(bills)..where((x) => x.id.equals(b.id))).write(
    BillsCompanion(nextDue: Value(advanceDue(b.nextDue, b.frequency)), active: Value(b.frequency != 'once')),
  );
}

/// A link plus the transaction at its other end.
class LinkView {
  const LinkView(this.link, this.other);
  final TxnLink link;
  final Transaction other;
}
