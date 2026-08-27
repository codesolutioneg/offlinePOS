import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/diagnostics/startup_log.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('startup_log_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  File logFile() => File('${dir.path}${Platform.pathSeparator}${StartupLog.fileName}');

  test('the last line is the step that never finished', () {
    final log = StartupLog(logFile())..begin('1.2.3');
    log.step('read the database key from the platform keychain');
    log.step('open and migrate the encrypted database');
    // Nothing after this: the step blocked, exactly as a held file lock would.

    final lines = logFile().readAsLinesSync();
    expect(lines.last, contains('open and migrate the encrypted database'));
  });

  test('a step is on disk before the work it names could block', () {
    final log = StartupLog(logFile())..begin('1.2.3');
    log.step('open and migrate the encrypted database');

    // Read with no close, flush or dispose: a launch that hangs never gets to
    // any of those, so an unflushed write would leave support with an empty file.
    expect(logFile().readAsStringSync(), contains('open and migrate'));
  });

  test('a failure records the reason and the stack', () {
    final log = StartupLog(logFile())..begin('1.2.3');
    try {
      throw StateError('file is not a database');
    } catch (error, stack) {
      log.failed(error, stack);
    }

    final written = logFile().readAsStringSync();
    expect(written, contains('FAILED: Bad state: file is not a database'));
    expect(written, contains('startup_log_test.dart'));
  });

  test('every line is stamped and says which launch it belongs to', () {
    StartupLog(logFile())
      ..begin('1.2.3+42')
      ..step('read the build configuration');

    final lines = logFile().readAsLinesSync();
    expect(lines.first, contains('--- launch 1.2.3+42 on '));
    expect(
      lines.every((l) => DateTime.tryParse(l.split(' ').first) != null),
      isTrue,
      reason: 'a line support cannot place in time is not worth writing',
    );
  });

  test('an earlier launch is kept, so a good one can be compared with a bad one', () {
    StartupLog(logFile())
      ..begin('1.2.3')
      ..step('render the first frame');
    StartupLog(logFile())
      ..begin('1.2.3')
      ..step('open and migrate the encrypted database');

    final written = logFile().readAsStringSync();
    expect(written, contains('render the first frame'));
    expect('--- launch'.allMatches(written).length, 2);
  });

  test('a log grown past the cap is dropped rather than kept forever', () {
    logFile().writeAsStringSync('x' * (StartupLog.maxBytes + 1));

    StartupLog(logFile()).begin('1.2.3');

    final written = logFile().readAsStringSync();
    expect(written, isNot(contains('xxx')));
    expect(written, contains('--- launch 1.2.3'));
  });

  test('the chosen directory is writable, and is the exe folder or temp', () {
    final chosen = StartupLog.bestDirectory();
    // Whatever it picks must actually be writable, or the log is lost.
    final probe = File('${chosen.path}${Platform.pathSeparator}.bd_write_test');
    expect(() {
      probe.writeAsStringSync('x', flush: true);
      probe.deleteSync();
    }, returnsNormally);
    // Next to the executable when that folder is writable, else the temp fallback.
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    expect([exeDir, Directory.systemTemp.path], contains(chosen.path));
  });

  test('a log that cannot be written never stops the till opening', () {
    final unwritable = File('${dir.path}/no/such/dir/${StartupLog.fileName}');
    final log = StartupLog(unwritable);

    expect(() {
      log
        ..begin('1.2.3')
        ..step('open and migrate the encrypted database')
        ..failed(StateError('nope'), StackTrace.current);
    }, returnsNormally);
  });
}
