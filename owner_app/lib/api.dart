import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'report_keys.dart';

class ApiError implements Exception {
  ApiError(this.message, {this.status});
  final String message;
  final int? status;
  bool get signedOut => status == 401;
  @override
  String toString() => message;
}

class OwnerUser {
  const OwnerUser({
    required this.id,
    required this.username,
    required this.displayName,
    required this.role,
    required this.allBranches,
    required this.branchIds,
    required this.capabilities,
    required this.reportKeys,
    required this.active,
  });

  final String id;
  final String username;
  final String displayName;
  final String role;
  final bool allBranches;
  final List<String> branchIds;
  final Set<String> capabilities;
  final Set<String> reportKeys;
  final bool active;

  bool get isOwner => role == 'owner';

  bool canOpen(String key) =>
      isOwner || reportKeys.contains(key) || reportKeys.contains('*');

  factory OwnerUser.fromJson(Map<String, dynamic> m) {
    final keys = {
      for (final k in (m['report_keys'] as List? ?? const [])) '$k',
    };
    // Owners always get the full mobile pack.
    final role = '${m['role'] ?? 'manager'}';
    return OwnerUser(
      id: m['id'] as String,
      username: m['username'] as String,
      displayName: (m['display_name'] as String?) ?? m['username'] as String,
      role: role,
      allBranches: m['all_branches'] == true || role == 'owner',
      branchIds: [for (final id in (m['branch_ids'] as List? ?? const [])) '$id'],
      capabilities: {
        for (final c in (m['capabilities'] as List? ?? const [])) '$c'
      },
      reportKeys: role == 'owner' ? {...kOwnerReportKeys} : keys,
      active: m['active'] != false,
    );
  }
}

class OwnerBranch {
  const OwnerBranch({required this.id, required this.name});
  final String id;
  final String name;

  factory OwnerBranch.fromJson(Map<String, dynamic> m) => OwnerBranch(
        id: m['id'] as String,
        name: m['name'] as String,
      );
}

class OwnerSession {
  const OwnerSession({
    required this.user,
    required this.shopName,
    required this.branches,
  });
  final OwnerUser user;
  final String shopName;
  final List<OwnerBranch> branches;
}

class OwnerRecord {
  const OwnerRecord({
    required this.kind,
    required this.key,
    required this.branchId,
    required this.payload,
    this.at,
  });
  final String kind;
  final String key;
  final String branchId;
  final Map<String, Object?> payload;
  final DateTime? at;
}

/// Talks to the Dishflow reports API with a persisted session cookie.
class OwnerApi {
  OwnerApi({String? baseUrl})
      : baseUrl = (baseUrl ?? defaultBaseUrl).replaceAll(RegExp(r'/+$'), '');

  static const defaultBaseUrl = 'https://reports.dishflow.net';

  final String baseUrl;
  String? _cookie;
  final _client = http.Client();

  Future<void> loadCookie() async {
    final prefs = await SharedPreferences.getInstance();
    _cookie = prefs.getString('pos_session');
  }

  Future<void> _saveCookie(String? value) async {
    _cookie = value;
    final prefs = await SharedPreferences.getInstance();
    if (value == null || value.isEmpty) {
      await prefs.remove('pos_session');
    } else {
      await prefs.setString('pos_session', value);
    }
  }

  void _captureCookie(http.Response res) {
    final raw = res.headers['set-cookie'];
    if (raw == null) return;
    // set-cookie may list pos_session=...; Path=/; ...
    final match = RegExp(r'pos_session=([^;]+)').firstMatch(raw);
    if (match != null) {
      _saveCookie(match.group(1));
    }
  }

  Map<String, String> _headers({bool jsonBody = false}) => {
        'Accept': 'application/json',
        if (jsonBody) 'Content-Type': 'application/json',
        if (_cookie != null && _cookie!.isNotEmpty) 'Cookie': 'pos_session=$_cookie',
      };

  Future<Map<String, dynamic>> _call(
    String method,
    String path, [
    Map<String, Object?>? body,
    Map<String, String>? query,
  ]) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    late http.Response res;
    final headers = _headers(jsonBody: body != null);
    try {
      res = switch (method) {
        'GET' => await _client.get(uri, headers: headers),
        'POST' => await _client.post(uri,
            headers: headers, body: body == null ? null : jsonEncode(body)),
        'PATCH' => await _client.patch(uri,
            headers: headers, body: body == null ? null : jsonEncode(body)),
        'DELETE' => await _client.delete(uri, headers: headers),
        _ => throw ApiError('unsupported method $method'),
      };
    } catch (e) {
      if (e is ApiError) rethrow;
      throw ApiError('Could not reach the server');
    }
    _captureCookie(res);
    Map<String, dynamic> decoded = {};
    if (res.body.isNotEmpty) {
      try {
        final raw = jsonDecode(res.body);
        if (raw is Map) decoded = raw.cast<String, dynamic>();
      } catch (_) {}
    }
    if (res.statusCode >= 400) {
      throw ApiError(
        (decoded['error'] as String?) ?? 'Request failed (${res.statusCode})',
        status: res.statusCode,
      );
    }
    return decoded;
  }

  Future<void> login(String username, String password) async {
    await _call('POST', '/api/auth/login', {
      'username': username.trim().toLowerCase(),
      'password': password,
    });
  }

  Future<void> logout() async {
    try {
      await _call('POST', '/api/auth/logout');
    } finally {
      await _saveCookie(null);
    }
  }

  Future<OwnerSession?> session() async {
    try {
      final body = await _call('GET', '/api/me');
      final shop = (body['shop'] as Map?)?.cast<String, dynamic>() ?? {};
      return OwnerSession(
        user: OwnerUser.fromJson(
            (body['user'] as Map).cast<String, dynamic>()),
        shopName: (shop['name'] as String?) ?? '',
        branches: [
          for (final b in (body['branches'] as List? ?? const []))
            OwnerBranch.fromJson((b as Map).cast<String, dynamic>()),
        ],
      );
    } on ApiError catch (e) {
      if (e.signedOut) return null;
      rethrow;
    }
  }

  Future<List<OwnerRecord>> records(
    List<String> kinds, {
    String? branchId,
    DateTime? from,
    DateTime? to,
  }) async {
    final body = await _call('GET', '/api/records', null, {
      'kinds': kinds.join(','),
      'branch': branchId ?? 'all',
      if (from != null) 'from': from.toUtc().toIso8601String(),
      if (to != null) 'to': to.toUtc().toIso8601String(),
    });
    return [
      for (final r in (body['records'] as List? ?? const []))
        if (r is Map)
          OwnerRecord(
            kind: r['kind'] as String,
            key: r['key'] as String,
            branchId: r['branch_id'] as String? ?? '',
            at: DateTime.tryParse('${r['at'] ?? ''}'),
            payload:
                ((r['payload'] as Map?) ?? const {}).cast<String, Object?>(),
          ),
    ];
  }

  Future<List<OwnerUser>> users() async {
    final body = await _call('GET', '/api/users');
    return [
      for (final u in (body['users'] as List? ?? const []))
        OwnerUser.fromJson((u as Map).cast<String, dynamic>()),
    ];
  }

  Future<OwnerUser> updateUser(
    String id, {
    Set<String>? reportKeys,
    String? displayName,
    bool? active,
  }) async {
    final body = await _call('PATCH', '/api/users/$id', {
      if (reportKeys != null) 'report_keys': reportKeys.toList(),
      if (displayName != null) 'display_name': displayName,
      if (active != null) 'active': active,
    });
    return OwnerUser.fromJson((body['user'] as Map).cast<String, dynamic>());
  }
}
