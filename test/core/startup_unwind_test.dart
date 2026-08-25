import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/diagnostics/startup_log.dart';
import 'package:offline_pos/core/diagnostics/startup_unwind.dart';

void main() {
  late Directory dir;
  late StartupLog log;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('unwind_test');
    log = StartupLog(File('${dir.path}/log.txt'));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a service is stopped before the database it was writing through', () {
    final order = <String>[];
    final unwind = StartupUnwind()
      ..add(() => order.add('close the database'))
      ..add(() => order.add('stop the sync service'));

    unwind.run(log);

    expect(order, ['stop the sync service', 'close the database']);
  });

  test('a teardown that fails does not stop the rest, or hide the real reason', () {
    final closed = <String>[];
    final unwind = StartupUnwind()
      ..add(() => closed.add('database'))
      ..add(() => throw StateError('the timer was already gone'))
      ..add(() => closed.add('lan'));

    expect(() => unwind.run(log), returnsNormally);

    expect(closed, ['lan', 'database'], reason: 'one bad teardown must not skip the others');
    expect(
      File('${dir.path}/log.txt').readAsStringSync(),
      contains('could not undo a started service'),
    );
  });

  test('a launch that got nowhere has nothing to undo', () {
    final unwind = StartupUnwind();

    expect(unwind.length, 0);
    expect(() => unwind.run(log), returnsNormally);
  });

  test('nothing is closed twice', () {
    var closes = 0;
    final unwind = StartupUnwind()..add(() => closes++);

    unwind
      ..run(log)
      ..run(log);

    expect(closes, 1);
  });
}
