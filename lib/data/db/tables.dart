import 'package:drift/drift.dart';

/// Where a piece of evidence came from.
enum SourceKind { sms, email, manual, shortcut }

enum TxnDirection { debit, credit }

/// Payment rail detected from the message.
enum PaymentMode { upi, card, netbanking, neft, imps, rtgs, atm, wallet, cash, other }

/// How confident we are that a transaction is real and correctly read.
enum TxnStatus { confirmed, needsReview }

/// Lifecycle of a raw message as it moves through ingestion.
enum ParseStatus { parsed, merged, ignored, failed, pendingLlm }

enum AccountKind { bank, creditCard, wallet, cash }

class Accounts extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  IntColumn get kind => intEnum<AccountKind>()();
  TextColumn get institution => text().nullable()();

  /// Last 3–4 digits of account / card number, used to match messages.
  TextColumn get last4 => text().nullable()();
  IntColumn get color => integer()();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();

  /// ISO 4217 code the account is held in. Rows from before v4 are INR.
  TextColumn get currency => text().withDefault(const Constant('INR'))();

  /// Last known balance in minor units of [currency], taken from the most
  /// recent bank message that stated one (or typed in by the user).
  IntColumn get balanceMinor => integer().nullable()();

  /// When that balance was true: the time of the message it came from.
  DateTimeColumn get balanceAt => dateTime().nullable()();

  /// True when the user typed [balanceMinor] in rather than an SMS stating it.
  BoolColumn get balanceManual => boolean().withDefault(const Constant(false))();
}

class Categories extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();

  /// Key into [CategoryIcons]; stored as text so icon sets can change.
  TextColumn get icon => text()();
  IntColumn get color => integer()();
  BoolColumn get isIncome => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// Name of the seed category this row was created from (null for
  /// user-made ones). Keeps keyword rules working after a rename.
  TextColumn get seedName => text().nullable()();
}

class Transactions extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// In minor units of [currency] (paise, cents; whole yen for JPY, fils
  /// for KWD) to avoid floating point drift.
  IntColumn get amountMinor => integer()();

  /// ISO 4217 code of [amountMinor]. Rows from before v4 are INR.
  TextColumn get currency => text().withDefault(const Constant('INR'))();

  /// The same payment in another currency, normally the home currency:
  /// stated by the message ("USD 12.50 (INR 1,045.30)") or entered by the
  /// user. A foreign transaction counts towards totals and budgets only
  /// with a converted amount in the home currency. Null for most rows.
  IntColumn get convertedMinor => integer().nullable()();
  TextColumn get convertedCurrency => text().nullable()();
  IntColumn get direction => intEnum<TxnDirection>()();
  DateTimeColumn get occurredAt => dateTime()();
  TextColumn get merchant => text().nullable()();

  /// VPA / raw counterparty string as it appeared in the message.
  TextColumn get counterparty => text().nullable()();
  TextColumn get note => text().nullable()();
  IntColumn get categoryId => integer().nullable().references(Categories, #id)();
  IntColumn get accountId => integer().nullable().references(Accounts, #id)();
  TextColumn get accountHint => text().nullable()();
  IntColumn get mode => intEnum<PaymentMode>()();

  /// UPI ref / RRN / bank reference. The strongest dedup signal.
  TextColumn get reference => text().nullable()();
  IntColumn get status => intEnum<TxnStatus>()();

  /// Self-transfers between own accounts are excluded from spend.
  BoolColumn get isTransfer => boolean().withDefault(const Constant(false))();
  BoolColumn get categoryLocked => boolean().withDefault(const Constant(false))();

  /// Set when dedup found a borderline match the user should confirm.
  IntColumn get duplicateOfId => integer().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// Part of this amount that is accounted for by [TxnLinks]: for a payment,
  /// what friends paid back; for a credit, how much of it was a repayment
  /// (not income). Totals use `amount − linkedMinor` (see `TxnMoney`).
  IntColumn get linkedMinor => integer().withDefault(const Constant(0))();

  /// The other leg of a self-transfer (debit ↔ credit), when known.
  IntColumn get transferPairId => integer().nullable()();
}

/// Every SMS / email we have looked at, parsed or not. Keeping the raw
/// evidence lets us re-parse after parser upgrades and explain merges.
class RawMessages extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get source => intEnum<SourceKind>()();

  /// Provider-side id (SMS _id, Gmail message id) — unique per source.
  TextColumn get externalId => text()();
  TextColumn get sender => text()();
  TextColumn get body => text()();
  DateTimeColumn get receivedAt => dateTime()();
  IntColumn get parseStatus => intEnum<ParseStatus>()();
  TextColumn get ignoreReason => text().nullable()();
  IntColumn get transactionId => integer().nullable().references(Transactions, #id, onDelete: KeyAction.setNull)();

  /// Dedup score that linked this message to an existing transaction.
  RealColumn get mergeScore => real().nullable()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {source, externalId},
  ];
}

/// Monthly spending limits. A row with a null [categoryId] is the overall
/// monthly budget (at most one); others cap a single category. Budgets
/// repeat every month until removed or paused.
class Budgets extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get categoryId => integer().nullable().references(Categories, #id, onDelete: KeyAction.cascade)();

  /// Limit per month, in minor units of [currency].
  IntColumn get amountMinor => integer()();

  /// A budget applies only while this is the home currency. Rows from
  /// before v4 are INR.
  TextColumn get currency => text().withDefault(const Constant('INR'))();
  BoolColumn get active => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// Learned "merchant → category" mappings, created when the user
/// recategorises a transaction.
class MerchantRules extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get pattern => text().unique()();
  IntColumn get categoryId => integer().references(Categories, #id, onDelete: KeyAction.cascade)();
}

/// A message format the user taught the app ("Teach Pckt"). Tried before the
/// built-in parser. [specJson] is a `TemplateSpec` (see
/// `ingestion/templates/template_engine.dart`); [sampleBody] is the message it
/// was taught from, so the template can be re-opened and edited.
class ParserTemplates extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();

  /// Sender header the template is limited to (e.g. `HDFCBK`), null = any.
  TextColumn get senderPattern => text().nullable()();
  TextColumn get specJson => text()();
  TextColumn get sampleBody => text()();
  TextColumn get sampleSender => text().nullable()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  /// How many messages this template has read.
  IntColumn get hits => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// "This received money (or part of it) settles that payment": splits with
/// friends, refunds, reimbursements. [amountMinor] is the part of the credit
/// that offsets the payment, in their shared currency.
class TxnLinks extends Table {
  IntColumn get id => integer().autoIncrement()();
  @ReferenceName('paymentLinks')
  IntColumn get paymentId => integer().references(Transactions, #id, onDelete: KeyAction.cascade)();
  @ReferenceName('receivedLinks')
  IntColumn get receivedId => integer().references(Transactions, #id, onDelete: KeyAction.cascade)();
  IntColumn get amountMinor => integer()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// A bill or subscription entered by hand, with a reminder.
class Bills extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  IntColumn get amountMinor => integer().withDefault(const Constant(0))();
  TextColumn get currency => text().withDefault(const Constant('INR'))();

  /// `once`, `weekly`, `biweekly`, `monthly`, `quarterly`, `halfyearly`, `yearly`.
  TextColumn get frequency => text().withDefault(const Constant('monthly'))();

  /// The next date the bill is due (date only; time of day is ignored).
  DateTimeColumn get nextDue => dateTime()();

  /// Remind this many days before [nextDue] (0 = on the day). A reminder
  /// is always also sent on the due date itself.
  IntColumn get remindDaysBefore => integer().withDefault(const Constant(1))();
  BoolColumn get isSubscription => boolean().withDefault(const Constant(false))();
  IntColumn get categoryId => integer().nullable().references(Categories, #id, onDelete: KeyAction.setNull)();
  IntColumn get accountId => integer().nullable().references(Accounts, #id, onDelete: KeyAction.setNull)();
  TextColumn get note => text().nullable()();
  BoolColumn get active => boolean().withDefault(const Constant(true))();
  DateTimeColumn get lastPaidAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
