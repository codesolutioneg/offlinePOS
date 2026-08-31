import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/features/tables/reservations_screen.dart';

/// Which instant a typed booking time means.
///
/// Tested without a clock, because the bug this covers only appeared for the
/// twenty minutes either side of midnight and a test that has to be run at 23:50
/// to fail is a test nobody trusts.
void main() {
  DateTime? at(String raw, DateTime now, {bool tomorrow = false}) =>
      reservationTimeFrom(raw, now, tomorrow: tomorrow)?.toLocal();

  test('a time later today is today', () {
    final now = DateTime(2026, 3, 4, 18, 00);
    expect(at('19:30', now), DateTime(2026, 3, 4, 19, 30));
  });

  test('a booking taken before midnight for after it lands tonight', () {
    // The shop is open, the kitchen is serving, and the guests are coming in
    // twenty minutes. Filed as this morning it is most of a day in the past: it
    // never shows on the floor and nobody holds the table.
    final now = DateTime(2026, 3, 4, 23, 50);
    expect(at('00:10', now), DateTime(2026, 3, 5, 0, 10));
  });

  test('any time already gone today rolls to the next one', () {
    final now = DateTime(2026, 3, 4, 21, 00);
    expect(at('09:00', now), DateTime(2026, 3, 5, 9, 0));
  });

  test('tomorrow still means tomorrow', () {
    // Taken in the afternoon for the next evening, which is the toggle's job and
    // must not be second-guessed by the rule above.
    final now = DateTime(2026, 3, 4, 15, 00);
    expect(at('19:30', now, tomorrow: true), DateTime(2026, 3, 5, 19, 30));
  });

  test('a time right now is now, not a day away', () {
    final now = DateTime(2026, 3, 4, 19, 30);
    expect(at('19:30', now), DateTime(2026, 3, 4, 19, 30));
  });

  test('what is not a time is refused', () {
    final now = DateTime(2026, 3, 4, 12, 00);
    expect(at('', now), isNull);
    expect(at('half seven', now), isNull);
    expect(at('19', now), isNull);
    expect(at('25:00', now), isNull);
    expect(at('19:60', now), isNull);
  });
}
