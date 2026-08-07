import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/print_job_store.dart';
import 'package:offline_pos/core/printing/printer_transport.dart';
import 'package:offline_pos/core/printing/spool_store.dart';

import '../db/sqlite_loader.dart';

/// A printer that is off until someone plugs it back in.
class Switchable implements PrinterTransport {
  bool on = false;
  final List<Uint8List> printed = [];

  @override
  Future<void> send(Uint8List bytes) async {
    if (!on) throw PrinterUnavailable('switched off');
    printed.add(bytes);
  }
}

Uint8List receipt(String text) => Uint8List.fromList(text.codeUnits);

void main() {
  late Db db;

  setUpAll(useSystemSqlite);
  setUp(() => db = Db.open(':memory:'));
  tearDown(() => db.close());

  SpooledPrinter printerOver(
    Switchable transport, {
    int maxSpool = 100,
    void Function(SpooledJob)? onDropped,
  }) =>
      SpooledPrinter(
        transport,
        spool: SqlitePrintJobStore(db, printer: 'receipt'),
        maxSpool: maxSpool,
        onDropped: onDropped,
      );

  test('receipts held during a rush survive the app being closed', () async {
    final printer = Switchable();
    final beforeRestart = printerOver(printer);

    for (final order in ['one', 'two', 'three']) {
      await expectLater(
        beforeRestart.send(receipt(order), reference: order),
        throwsA(isA<PrinterUnavailable>()),
      );
    }
    expect(beforeRestart.spooledCount, 3);

    // A till is restarted nightly, which used to be exactly when the backlog
    // disappeared. The spool object is new; the queue behind it is not.
    final afterRestart = printerOver(printer);
    expect(afterRestart.spooledCount, 3);

    printer.on = true;
    expect(await afterRestart.flush(), 3);
    expect(afterRestart.hasSpooled, isFalse);
    expect(
      printer.printed.map((b) => String.fromCharCodes(b)),
      ['one', 'two', 'three'],
      reason: 'a kitchen reading tickets out of order is worse than reading late',
    );
  });

  test('a held receipt says which sale it belongs to', () async {
    final spool = printerOver(Switchable());
    await expectLater(
      spool.send(receipt('x'), reference: 'order-abc'),
      throwsA(isA<PrinterUnavailable>()),
    );
    expect((await spool.held()).single.reference, 'order-abc');
  });

  test('a receipt forced out by the cap is reported, never dropped quietly',
      () async {
    final dropped = <String?>[];
    final spool = printerOver(Switchable(),
        maxSpool: 2, onDropped: (job) => dropped.add(job.reference));

    for (final order in ['a', 'b', 'c']) {
      await expectLater(
          spool.send(receipt(order), reference: order), throwsException);
    }

    // The cap stops a printer left off for a week filling the disk, but a
    // discarded receipt is a customer with no proof of payment, so somebody is
    // told which one went.
    expect(dropped, ['a']);
    expect(spool.spooledCount, 2);
  });

  test('a flush that hits a dead printer keeps the rest of the queue in order',
      () async {
    final printer = Switchable();
    final spool = printerOver(printer);
    for (final order in ['a', 'b']) {
      await expectLater(
          spool.send(receipt(order), reference: order), throwsException);
    }

    expect(await spool.flush(), 0);
    expect(spool.spooledCount, 2);
    expect((await spool.held()).first.attempts, 1,
        reason: 'the failure is recorded against the job, not lost');
  });
}
