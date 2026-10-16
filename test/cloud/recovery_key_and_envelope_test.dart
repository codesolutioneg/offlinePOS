import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/cloud/backup_envelope.dart';
import 'package:offline_pos/core/cloud/recovery_key.dart';

Uint8List _bytes(int n, [int seed = 1]) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

BackupHeader _header(Uint8List db) => BackupHeader(
      deviceId: 'till-1',
      deviceName: 'Front counter',
      createdAt: DateTime.utc(2026, 10, 8, 12, 30),
      appVersion: '1.2.3',
      dbSha256: crypto.sha256.convert(db).toString(),
      dbKey: 'abc123',
    );

void main() {
  group('RecoveryKey', () {
    test('reads back what it writes', () {
      final key = RecoveryKey.generate();
      final text = key.format();
      expect(text.replaceAll('-', ''), hasLength(52));
      expect(text.split('-'), hasLength(13));
      expect(RecoveryKey.parse(text).bytes, key.bytes);
    });

    test('forgives what a person does copying it off paper', () {
      final key = RecoveryKey.generate();
      final sloppy = key
          .format()
          .toLowerCase()
          .replaceAll('-', ' ')
          .replaceAll('0', 'o')
          .replaceAll('1', 'l');
      expect(RecoveryKey.parse(sloppy).bytes, key.bytes);
      expect(RecoveryKey.parse(sloppy).id, key.id);
    });

    test('refuses a key with a character missing or a wrong one', () {
      final text = RecoveryKey.generate().format().replaceAll('-', '');
      expect(() => RecoveryKey.parse(text.substring(1)), throwsFormatException);
      expect(() => RecoveryKey.parse('${text.substring(1)}U'), throwsFormatException);
      expect(() => RecoveryKey.parse(''), throwsFormatException);
    });

    test('the id names the key without being it', () {
      final a = RecoveryKey.generate();
      final b = RecoveryKey.generate();
      expect(a.id, hasLength(12));
      expect(a.id, isNot(b.id));
      expect(RecoveryKey.parse(a.format()).id, a.id);
    });
  });

  group('BackupEnvelope', () {
    test('opens with the key it was sealed with', () async {
      final key = RecoveryKey.generate();
      final db = _bytes(200000);
      final sealed = await BackupEnvelope.seal(_header(db), db, key);

      final opened = await BackupEnvelope.open(sealed, key);
      expect(opened.database, db);
      expect(opened.header.deviceId, 'till-1');
      expect(opened.header.deviceName, 'Front counter');
      expect(opened.header.dbKey, 'abc123');
      expect(opened.header.createdAt, DateTime.utc(2026, 10, 8, 12, 30));
      expect(opened.header.dbSha256, crypto.sha256.convert(db).toString());
    });

    test('the database is not readable in what is uploaded', () async {
      final db = Uint8List.fromList('SQLite format 3 secret-sales-row'.codeUnits);
      final sealed = await BackupEnvelope.seal(_header(db), db, RecoveryKey.generate());
      expect(String.fromCharCodes(sealed).contains('secret-sales-row'), isFalse);
      expect(String.fromCharCodes(sealed).contains('abc123'), isFalse);
    });

    test('another key does not open it', () async {
      final db = _bytes(1000);
      final sealed = await BackupEnvelope.seal(_header(db), db, RecoveryKey.generate());
      expect(BackupEnvelope.open(sealed, RecoveryKey.generate()),
          throwsA(isA<WrongRecoveryKey>()));
    });

    test('a changed byte is caught, not restored', () async {
      final key = RecoveryKey.generate();
      final db = _bytes(1000);
      final sealed = await BackupEnvelope.seal(_header(db), db, key);
      sealed[sealed.length - 10] ^= 1;
      expect(BackupEnvelope.open(sealed, key), throwsA(isA<WrongRecoveryKey>()));
    });

    test('something that is not a backup says so', () async {
      expect(BackupEnvelope.open(_bytes(100), RecoveryKey.generate()),
          throwsFormatException);
    });
  });
}
