import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/db_key.dart';
import 'package:offline_pos/core/diagnostics/startup_failure_app.dart';

void main() {
  group('what the operator is told', () {
    test('a keychain that never answered says so, and says do not reinstall', () {
      final failure = StartupFailure.of(const MissingDatabaseKey(5));

      expect(failure.code, 'E-KEY');
      expect(failure.english, contains('do not reinstall'));
    });

    test('a key that does not fit the file becomes a call, not a reinstall', () {
      // SQLCipher's own words for a wrong key, which is the failure that must
      // never be answered by deleting anything.
      final failure = StartupFailure.of(
        Exception('SqliteException(26): file is not a database'),
      );

      expect(failure.code, 'E-DATA');
      expect(failure.english, contains('Call support'));
      expect(failure.english, contains('do not delete'));
    });

    test('a held file becomes an instruction anyone can follow', () {
      final failure = StartupFailure.of(Exception('SqliteException(5): database is locked'));

      expect(failure.code, 'E-BUSY');
      expect(failure.english, contains('Restart the computer'));
    });

    test('an unrecognised failure still gets a code and a next step', () {
      final failure = StartupFailure.of(Exception('something nobody predicted'));

      expect(failure.code, 'E-START');
      expect(failure.english, contains('Restart the computer'));
    });

    test('every failure is told in both languages the shop runs in', () {
      for (final error in <Object>[
        const MissingDatabaseKey(5),
        Exception('file is not a database'),
        Exception('database is locked'),
        Exception('unknown'),
      ]) {
        final failure = StartupFailure.of(error);
        expect(failure.english, isNotEmpty);
        expect(failure.arabic, isNotEmpty);
        expect(
          failure.arabic,
          isNot(failure.english),
          reason: 'an untranslated instruction is no instruction at all',
        );
      }
    });
  });

  testWidgets('the screen leads with the instruction, not the exception',
      (tester) async {
    await tester.pumpWidget(const StartupFailureApp(
      error: 'SqliteException(26): file is not a database',
      logPath: r'C:\Temp\offline_pos_startup.log',
      reportPath: r'C:\Users\till\Desktop\offline_pos_problem_report.txt',
    ));

    expect(find.textContaining('E-DATA'), findsOneWidget);
    expect(find.textContaining('cannot read its saved sales'), findsOneWidget);
    expect(find.textContaining('لا تستطيع نقطة البيع'), findsOneWidget);
    // Once per language: the path is the actionable part of the sentence, so it
    // is repeated rather than left out of one of them.
    expect(find.textContaining('offline_pos_problem_report.txt'), findsNWidgets(2));
    // Present for whoever is called, but not as the headline.
    expect(find.textContaining('SqliteException(26)'), findsOneWidget);
  });

  testWidgets('a report that could not be saved simply is not promised',
      (tester) async {
    await tester.pumpWidget(const StartupFailureApp(
      error: 'nope',
      logPath: r'C:\Temp\offline_pos_startup.log',
    ));

    expect(find.textContaining('A report has been saved'), findsNothing);
    expect(find.textContaining('E-START'), findsOneWidget);
  });
}
