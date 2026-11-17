// Pure scheduling rules for bills and subscriptions (no Flutter / DB), so
// they can be unit-tested.

const billFrequencies = ['once', 'weekly', 'biweekly', 'monthly', 'quarterly', 'halfyearly', 'yearly'];

String frequencyLabel(String f) => switch (f) {
  'once' => 'One time',
  'weekly' => 'Weekly',
  'biweekly' => 'Every 2 weeks',
  'monthly' => 'Monthly',
  'quarterly' => 'Every 3 months',
  'halfyearly' => 'Every 6 months',
  'yearly' => 'Yearly',
  _ => f,
};

/// Approximate number of times per month, to total a monthly outgo.
double timesPerMonth(String f) => switch (f) {
  'weekly' => 52 / 12,
  'biweekly' => 26 / 12,
  'monthly' => 1,
  'quarterly' => 1 / 3,
  'halfyearly' => 1 / 6,
  'yearly' => 1 / 12,
  _ => 0,
};

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// [d] moved forward by [months], keeping the day of month where the target
/// month has it (31 Jan + 1 month = 28/29 Feb, never 3 Mar).
DateTime addMonthsClamped(DateTime d, int months) {
  final first = DateTime(d.year, d.month + months);
  final last = DateTime(first.year, first.month + 1, 0).day;
  return DateTime(first.year, first.month, d.day > last ? last : d.day);
}

/// The due date after [due] for a bill that repeats at [frequency].
DateTime advanceDue(DateTime due, String frequency) => switch (frequency) {
  'weekly' => DateTime(due.year, due.month, due.day + 7),
  'biweekly' => DateTime(due.year, due.month, due.day + 14),
  'monthly' => addMonthsClamped(due, 1),
  'quarterly' => addMonthsClamped(due, 3),
  'halfyearly' => addMonthsClamped(due, 6),
  'yearly' => addMonthsClamped(due, 12),
  _ => dateOnly(due),
};

/// Whole days from [today] to [due] (negative when overdue).
int daysUntil(DateTime due, DateTime today) => dateOnly(due).difference(dateOnly(today)).inDays;

/// "Due today", "Due tomorrow", "Due in 5 days", "2 days overdue".
String dueLabel(DateTime due, DateTime today) {
  final n = daysUntil(due, today);
  if (n == 0) return 'Due today';
  if (n == 1) return 'Due tomorrow';
  if (n > 1) return 'Due in $n days';
  return n == -1 ? '1 day overdue' : '${-n} days overdue';
}

/// When to notify for one bill: [remindDaysBefore] days ahead and on the
/// day, both at [hour]:00 local time, keeping only moments after [now].
List<({DateTime at, bool early})> reminderMoments(DateTime due, int remindDaysBefore, DateTime now, {int hour = 9}) {
  final day = dateOnly(due);
  final out = <({DateTime at, bool early})>[];
  if (remindDaysBefore > 0) {
    final early = DateTime(day.year, day.month, day.day - remindDaysBefore, hour);
    if (early.isAfter(now)) out.add((at: early, early: true));
  }
  final onDay = DateTime(day.year, day.month, day.day, hour);
  if (onDay.isAfter(now)) out.add((at: onDay, early: false));
  return out;
}
