/// The trading day a sale belongs to.
///
/// Not the calendar date. A restaurant that closes at 02:00 books those sales
/// against the evening that produced them, so a shift running past midnight stays
/// on one day's report and one cash-up. Getting this wrong splits a single service
/// across two days and makes every daily figure argue with the till.
class BusinessDay {
  const BusinessDay(this.date);

  final DateTime date;

  /// What a shop trades on until it says otherwise: a kitchen that stops serving
  /// somewhere before 4am books the whole night on the evening it started.
  static const int defaultCutoverHour = 4;

  /// The hour this shop's trading day rolls over, published from the on-device
  /// setting so that every order, wherever it is created (a sale, a split check, a
  /// refund), is stamped with one rule instead of each construction site being
  /// handed the setting separately. Same shape, and for the same reason, as the
  /// print profile the printing layer reads.
  ///
  /// Read once when an order is created, never when a total or a report is asked
  /// for: changing the rule moves tomorrow's sales, not the ones already counted.
  static int shopCutoverHour = defaultCutoverHour;

  /// The trading day [at] falls in, given a [cutoverHour] in local time. Null takes
  /// the shop's published rule.
  ///
  /// With the default 04:00 cutover, anything before 4am is still yesterday's
  /// trading.
  factory BusinessDay.of(DateTime at, {int? cutoverHour}) {
    cutoverHour ??= shopCutoverHour;
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
