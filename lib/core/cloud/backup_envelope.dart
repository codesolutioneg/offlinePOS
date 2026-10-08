import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'recovery_key.dart';

/// What travels with the database inside a sealed backup.
///
/// [dbKey] is the till's database key. It has to travel: a restore lands on a
/// machine whose keychain never held it, and without it an encrypted database is
/// noise. It is only ever inside the sealed body, under the recovery key.
class BackupHeader {
  const BackupHeader({
    required this.deviceId,
    required this.deviceName,
    required this.createdAt,
    required this.appVersion,
    required this.dbSha256,
    this.dbKey,
  });

  final String deviceId;
  final String deviceName;
  final DateTime createdAt;
  final String appVersion;
  final String dbSha256;
  final String? dbKey;

  Map<String, Object?> toJson() => {
        'format': 1,
        'device_id': deviceId,
        'device_name': deviceName,
        'created_at': createdAt.toUtc().toIso8601String(),
        'app_version': appVersion,
        'db_sha256': dbSha256,
        'db_key': dbKey,
      };

  factory BackupHeader.fromJson(Map<String, dynamic> m) => BackupHeader(
        deviceId: m['device_id'] as String,
        deviceName: (m['device_name'] as String?) ?? '',
        createdAt: DateTime.parse(m['created_at'] as String),
        appVersion: (m['app_version'] as String?) ?? '',
        dbSha256: (m['db_sha256'] as String?) ?? '',
        dbKey: m['db_key'] as String?,
      );
}

/// A backup that opened: the header and the database file's bytes.
typedef OpenedBackup = ({BackupHeader header, Uint8List database});

/// The key is not the one this backup was sealed with, or the bytes were changed.
class WrongRecoveryKey implements Exception {
  const WrongRecoveryKey();
  @override
  String toString() =>
      'WrongRecoveryKey: this backup does not open with that recovery key';
}

/// The sealed form of a till's database for the cloud.
///
/// `OPCB` + version byte, then a 12-byte nonce, the 16-byte tag and the AES-256-GCM
/// ciphertext of gzip(header length, header JSON, database). The magic and version
/// are authenticated too, so a body cannot be relabelled as another format.
///
/// Sealing and opening run on a background isolate: a database of a few tens of
/// megabytes takes long enough in pure Dart to drop frames on the till.
class BackupEnvelope {
  BackupEnvelope._();

  static const List<int> _magic = [0x4F, 0x50, 0x43, 0x42, 1];
  static const int _nonceLength = 12;
  static const int _macLength = 16;

  static Future<Uint8List> seal(
          BackupHeader header, Uint8List database, RecoveryKey key) =>
      Isolate.run(() => _seal(header.toJson(), database, key.bytes));

  /// Throws [WrongRecoveryKey] when [key] does not open it, [FormatException]
  /// when it is not a sealed backup at all.
  static Future<OpenedBackup> open(Uint8List sealed, RecoveryKey key) async {
    final opened = await Isolate.run(() => _open(sealed, key.bytes));
    return (
      header: BackupHeader.fromJson(opened.header),
      database: opened.database,
    );
  }

  static Future<Uint8List> _seal(
      Map<String, Object?> header, Uint8List database, Uint8List key) async {
    final headerBytes = utf8.encode(jsonEncode(header));
    final plain = BytesBuilder(copy: false)
      ..add((ByteData(4)..setUint32(0, headerBytes.length)).buffer.asUint8List())
      ..add(headerBytes)
      ..add(database);
    final packed = gzip.encode(plain.takeBytes());
    final box = await AesGcm.with256bits().encrypt(
      packed,
      secretKey: SecretKey(key),
      aad: _magic,
    );
    return (BytesBuilder(copy: false)
          ..add(_magic)
          ..add(box.nonce)
          ..add(box.mac.bytes)
          ..add(box.cipherText))
        .takeBytes();
  }

  static Future<({Map<String, dynamic> header, Uint8List database})> _open(
      Uint8List sealed, Uint8List key) async {
    const head = 5 + _nonceLength + _macLength;
    if (sealed.length < head) throw const FormatException('too short to be a backup');
    for (var i = 0; i < _magic.length; i++) {
      if (sealed[i] != _magic[i]) throw const FormatException('not a cloud backup');
    }
    final box = SecretBox(
      Uint8List.sublistView(sealed, head),
      nonce: Uint8List.sublistView(sealed, 5, 5 + _nonceLength),
      mac: Mac(Uint8List.sublistView(sealed, 5 + _nonceLength, head)),
    );
    final List<int> packed;
    try {
      packed = await AesGcm.with256bits()
          .decrypt(box, secretKey: SecretKey(key), aad: _magic);
    } on SecretBoxAuthenticationError {
      throw const WrongRecoveryKey();
    }
    final plain = Uint8List.fromList(gzip.decode(packed));
    final length = ByteData.sublistView(plain, 0, 4).getUint32(0);
    final header = jsonDecode(utf8.decode(Uint8List.sublistView(plain, 4, 4 + length)))
        as Map<String, dynamic>;
    return (header: header, database: Uint8List.sublistView(plain, 4 + length));
  }
}
