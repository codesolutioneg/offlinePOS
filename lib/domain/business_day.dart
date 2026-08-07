/// The trading day a sale belongs to.
///
/// Not the calendar date. A restaurant that closes at 02:00 books those sales
/// against the evening that produced them, so a shift running past midnight stays
/// on one day's report and one cash-up. Getting this wrong splits a single service
/// across two days and makes every daily figure argue with the till.
class BusinessDay {
  const BusinessDay(this.date);

  final DateTime date;

  /// The trading day [at] falls in, given a [cutoverHour] in local time.
  ///
  /// With the default 04:00 cutover, anything before 4am is still yesterday's
  /// trading.
  factory BusinessDay.of(DateTime at, {int cutoverHour = 4}) {
    final local = at.toLocal();
    final shifted = local.hour < cutoverHour
        ? local.subtract(const Duration(days: 1))
        : local;
    return BusinessDay(DateTime(shifted.year, shifted.month, shifted.day));
  }

  /// ISO date, which is what the server keys a session on.
  String get key =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  @override
  bool operator ==(Object other) => other is BusinessDay && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => key;
}
