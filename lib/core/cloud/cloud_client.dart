import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

/// The server refused or failed a call. [status] is null when it was never
/// reached (no line, DNS, timeout).
class CloudError implements Exception {
  const CloudError(this.message, {this.status});

  final String message;
  final int? status;

  /// The device's token is no longer accepted: it has to be paired again.
  bool get unpaired => status == 401;

  @override
  String toString() => 'CloudError(${status ?? 'offline'}): $message';
}

/// One backup the shop holds on the server.
class CloudBackupInfo {
  const CloudBackupInfo({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.createdAt,
    required this.size,
    required this.reason,
    required this.keyId,
  });

  final String id;
  final String deviceId;
  final String deviceName;
  final DateTime createdAt;
  final int size;
  final String reason;
  final String keyId;

  factory CloudBackupInfo.fromJson(Map<String, dynamic> m) => CloudBackupInfo(
        id: m['id'] as String,
        deviceId: m['device_id'] as String,
        deviceName: (m['device_name'] as String?) ?? '',
        createdAt: DateTime.parse(m['created_at'] as String),
        size: (m['size'] as num).toInt(),
        reason: (m['reason'] as String?) ?? '',
        keyId: (m['key_id'] as String?) ?? '',
      );
}

/// The shop's backup server (see cloud/ in this repository).
///
/// Every call but [pair] carries the device's token. Nothing here retries: the
/// backup service decides when to try again, and a restore is a person waiting
/// for an answer.
class CloudClient {
  CloudClient(String baseUrl, {http.Client? client})
      : _base = Uri.parse(baseUrl.trim().replaceAll(RegExp(r'/+$'), '')),
        _http = client ?? http.Client();

  final Uri _base;
  final http.Client _http;

  static const Duration _timeout = Duration(seconds: 30);
  static const Duration _transferTimeout = Duration(minutes: 10);

  Uri _url(String path) => _base.replace(path: '${_base.path}$path');

  /// Trade the shop's pairing code for this device's token. [keyId] is the
  /// recovery key the shop's backups are already sealed under, null before the
  /// first one.
  Future<({String token, String shopName, String? keyId})> pair({
    required String pairCode,
    required String deviceId,
    required String deviceName,
    required String appVersion,
  }) async {
    final body = await _json(() => _http.post(
          _url('/v1/devices/pair'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            // A code copied out of right-to-left text carries invisible direction
            // marks the server would read as part of it.
            'pair_code': pairCode.replaceAll(RegExp(r'[^A-Za-z0-9-]'), ''),
            'device_id': deviceId,
            'device_name': deviceName,
            'app_version': appVersion,
          }),
        ));
    final shop = body['shop'] as Map?;
    final keyId = shop?['key_id'] as String?;
    return (
      token: body['token'] as String,
      shopName: (shop?['name'] as String?) ?? '',
      keyId: keyId == null || keyId.isEmpty ? null : keyId,
    );
  }

  /// Which shop the token belongs to. A cheap check that the pairing still holds.
  Future<String> shopName(String token) async {
    final body = await _json(() => _http.get(_url('/v1/me'), headers: _auth(token)));
    return ((body['shop'] as Map?)?['name'] as String?) ?? '';
  }

  /// Hand the server a batch of changed records for the reports site. Each is
  /// `{kind, key, at, payload}`; sending one again only overwrites it.
  Future<int> sync(String token, List<Map<String, Object?>> records) async {
    final body = await _json(() => _http.post(
          _url('/v1/sync'),
          headers: {..._auth(token), 'Content-Type': 'application/json'},
          body: jsonEncode({'records': records}),
        ));
    return (body['stored'] as num?)?.toInt() ?? 0;
  }

  Future<String> upload(
    String token,
    Uint8List sealed, {
    required DateTime createdAt,
    required String reason,
    required String keyId,
  }) async {
    final body = await _json(
      () => _http.post(
        _url('/v1/backups'),
        headers: {
          ..._auth(token),
          'Content-Type': 'application/octet-stream',
          'X-Backup-Sha256': crypto.sha256.convert(sealed).toString(),
          'X-Backup-Created-At': createdAt.toUtc().toIso8601String(),
          'X-Backup-Reason': reason,
          'X-Backup-Key-Id': keyId,
        },
        body: sealed,
      ),
      timeout: _transferTimeout,
    );
    return body['id'] as String;
  }

  /// Every backup the shop holds, newest first, from every device.
  Future<List<CloudBackupInfo>> list(String token) async {
    final body =
        await _json(() => _http.get(_url('/v1/backups'), headers: _auth(token)));
    return [
      for (final m in (body['backups'] as List).cast<Map<String, dynamic>>())
        CloudBackupInfo.fromJson(m),
    ];
  }

  Future<Uint8List> download(String token, String id) async {
    final res = await _send(
      () => _http.get(_url('/v1/backups/$id'), headers: _auth(token)),
      timeout: _transferTimeout,
    );
    return res.bodyBytes;
  }

  void close() => _http.close();

  Map<String, String> _auth(String token) => {'Authorization': 'Bearer $token'};

  Future<Map<String, dynamic>> _json(Future<http.Response> Function() call,
      {Duration timeout = _timeout}) async {
    final res = await _send(call, timeout: timeout);
    try {
      return jsonDecode(res.body) as Map<String, dynamic>;
    } on FormatException {
      throw CloudError('the server answered with something that is not JSON',
          status: res.statusCode);
    }
  }

  Future<http.Response> _send(Future<http.Response> Function() call,
      {required Duration timeout}) async {
    final http.Response res;
    try {
      res = await call().timeout(timeout);
    } catch (e) {
      throw CloudError('$e');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return res;
    var message = 'HTTP ${res.statusCode}';
    try {
      final error = (jsonDecode(res.body) as Map)['error'];
      if (error is String && error.isNotEmpty) message = error;
    } catch (_) {}
    throw CloudError(message, status: res.statusCode);
  }
}
