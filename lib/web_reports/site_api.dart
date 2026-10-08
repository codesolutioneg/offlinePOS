import 'dart:convert';

import 'package:http/http.dart' as http;

/// The server said no, or could not be reached ([status] null).
class SiteError implements Exception {
  const SiteError(this.message, {this.status});

  final String message;
  final int? status;

  bool get signedOut => status == 401;

  @override
  String toString() => message;
}

enum SiteRole { owner, manager, accountant }

class SiteUser {
  const SiteUser({
    required this.id,
    required this.username,
    required this.displayName,
    required this.role,
    required this.allBranches,
    required this.branchIds,
    required this.capabilities,
    required this.active,
    this.lastLoginAt,
  });

  final String id;
  final String username;
  final String displayName;
  final SiteRole role;
  final bool allBranches;
  final List<String> branchIds;
  final Set<String> capabilities;
  final bool active;
  final DateTime? lastLoginAt;

  bool get isOwner => role == SiteRole.owner;

  factory SiteUser.fromJson(Map<String, dynamic> m) => SiteUser(
        id: m['id'] as String,
        username: m['username'] as String,
        displayName: (m['display_name'] as String?) ?? m['username'] as String,
        role: SiteRole.values.firstWhere((r) => r.name == m['role'],
            orElse: () => SiteRole.manager),
        allBranches: m['all_branches'] == true,
        branchIds: [for (final id in (m['branch_ids'] as List? ?? const [])) '$id'],
        capabilities: {for (final c in (m['capabilities'] as List? ?? const [])) '$c'},
        active: m['active'] != false,
        lastLoginAt: DateTime.tryParse('${m['last_login_at'] ?? ''}'),
      );
}

class SiteBranch {
  const SiteBranch({required this.id, required this.name, this.devices = const []});

  final String id;
  final String name;
  final List<SiteDevice> devices;

  factory SiteBranch.fromJson(Map<String, dynamic> m) => SiteBranch(
        id: m['id'] as String,
        name: m['name'] as String,
        devices: [
          for (final d in (m['devices'] as List? ?? const []))
            SiteDevice.fromJson((d as Map).cast<String, dynamic>()),
        ],
      );
}

class SiteDevice {
  const SiteDevice({
    required this.id,
    required this.name,
    required this.appVersion,
    this.lastSeenAt,
    this.lastSyncAt,
    this.lastBackupAt,
  });

  final String id;
  final String name;
  final String appVersion;
  final DateTime? lastSeenAt;
  final DateTime? lastSyncAt;
  final DateTime? lastBackupAt;

  factory SiteDevice.fromJson(Map<String, dynamic> m) => SiteDevice(
        id: m['id'] as String,
        name: (m['name'] as String?) ?? m['id'] as String,
        appVersion: (m['app_version'] as String?) ?? '',
        lastSeenAt: DateTime.tryParse('${m['last_seen_at'] ?? ''}'),
        lastSyncAt: DateTime.tryParse('${m['last_sync_at'] ?? ''}'),
        lastBackupAt: DateTime.tryParse('${m['last_backup_at'] ?? ''}'),
      );
}

/// Who is signed in, the shop, and the branches they may see.
class SiteSession {
  const SiteSession({required this.user, required this.shopName, required this.branches});

  final SiteUser user;
  final String shopName;
  final List<SiteBranch> branches;
}

/// One uploaded row: a sale, a shift, a clock-in, an audit entry or a lookup.
class SiteRecord {
  const SiteRecord({
    required this.kind,
    required this.key,
    required this.branchId,
    required this.at,
    required this.payload,
  });

  final String kind;
  final String key;
  final String branchId;
  final DateTime? at;
  final Map<String, Object?> payload;
}

/// A user the owner is creating or changing. Null fields are left as they are.
class SiteUserDraft {
  const SiteUserDraft({
    this.username,
    this.displayName,
    this.role,
    this.password,
    this.allBranches,
    this.branchIds,
    this.capabilities,
    this.active,
  });

  final String? username;
  final String? displayName;
  final SiteRole? role;
  final String? password;
  final bool? allBranches;
  final List<String>? branchIds;
  final Set<String>? capabilities;
  final bool? active;

  Map<String, Object?> toJson() => {
        'username': ?username,
        'display_name': ?displayName,
        'role': ?role?.name,
        'password': ?password,
        'all_branches': ?allBranches,
        'branch_ids': ?branchIds,
        if (capabilities != null) 'capabilities': capabilities!.toList(),
        'active': ?active,
      };
}

/// The reports site's own API (`/api/...` in cloud/src/web.ts), on the origin
/// the page was served from. The session is a cookie the browser keeps.
class SiteApi {
  SiteApi({Uri? base, http.Client? client})
      : _base = base ??
            Uri(scheme: Uri.base.scheme, host: Uri.base.host, port: Uri.base.port),
        _http = client ?? http.Client();

  final Uri _base;
  final http.Client _http;

  Uri _url(String path, [Map<String, String>? query]) =>
      _base.replace(path: path, queryParameters: query);

  /// The signed-in session, or null when nobody is signed in.
  Future<SiteSession?> session() async {
    try {
      final body = await _call('GET', '/api/me');
      final shop = (body['shop'] as Map?) ?? const {};
      return SiteSession(
        user: SiteUser.fromJson((body['user'] as Map).cast<String, dynamic>()),
        shopName: (shop['name'] as String?) ?? '',
        branches: [
          for (final b in (body['branches'] as List? ?? const []))
            SiteBranch.fromJson((b as Map).cast<String, dynamic>()),
        ],
      );
    } on SiteError catch (e) {
      if (e.signedOut) return null;
      rethrow;
    }
  }

  Future<void> login(String username, String password) =>
      _call('POST', '/api/auth/login', {'username': username, 'password': password});

  Future<void> logout() => _call('POST', '/api/auth/logout');

  Future<void> changePassword(String current, String next) =>
      _call('POST', '/api/me/password', {'current': current, 'next': next});

  Future<List<SiteBranch>> branches() async {
    final body = await _call('GET', '/api/branches');
    return [
      for (final b in (body['branches'] as List? ?? const []))
        SiteBranch.fromJson((b as Map).cast<String, dynamic>()),
    ];
  }

  /// A new branch and the code its first till pairs with.
  Future<({SiteBranch branch, String pairCode})> addBranch(String name) async {
    final body = await _call('POST', '/api/branches', {'name': name});
    return (branch: SiteBranch.fromJson(body), pairCode: body['pair_code'] as String);
  }

  Future<void> renameBranch(String id, String name) =>
      _call('PATCH', '/api/branches/$id', {'name': name});

  /// The branch and everything its tills sent; the tills stop syncing.
  Future<void> deleteBranch(String id) => _call('DELETE', '/api/branches/$id');

  /// A fresh pairing code for a branch; the old one stops working.
  Future<String> newPairCode(String id) async =>
      (await _call('POST', '/api/branches/$id/pair-code'))['pair_code'] as String;

  /// Rows of [kinds] from one branch, or every branch the user may see when
  /// [branchId] is null, with `at` inside [from] (inclusive) to [to] (exclusive).
  Future<List<SiteRecord>> records(
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
          SiteRecord(
            kind: r['kind'] as String,
            key: r['key'] as String,
            branchId: r['branch_id'] as String,
            at: DateTime.tryParse('${r['at'] ?? ''}'),
            payload: ((r['payload'] as Map?) ?? const {}).cast<String, Object?>(),
          ),
    ];
  }

  Future<List<SiteUser>> users() async {
    final body = await _call('GET', '/api/users');
    return [
      for (final u in (body['users'] as List? ?? const []))
        SiteUser.fromJson((u as Map).cast<String, dynamic>()),
    ];
  }

  /// The new user, and the password the server made when none was given.
  Future<({SiteUser user, String? password})> addUser(SiteUserDraft draft) async {
    final body = await _call('POST', '/api/users', draft.toJson());
    return (
      user: SiteUser.fromJson((body['user'] as Map).cast<String, dynamic>()),
      password: body['password'] as String?,
    );
  }

  Future<SiteUser> updateUser(String id, SiteUserDraft draft) async {
    final body = await _call('PATCH', '/api/users/$id', draft.toJson());
    return SiteUser.fromJson((body['user'] as Map).cast<String, dynamic>());
  }

  Future<String> resetPassword(String id) async =>
      (await _call('POST', '/api/users/$id/reset-password'))['password'] as String;

  Future<void> deleteUser(String id) => _call('DELETE', '/api/users/$id');

  Future<Map<String, dynamic>> _call(String method, String path,
      [Map<String, Object?>? body, Map<String, String>? query]) async {
    final request = http.Request(method, _url(path, query));
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(request));
    } catch (e) {
      throw SiteError('$e');
    }
    Map<String, dynamic> json = const {};
    if (res.body.isNotEmpty) {
      try {
        json = (jsonDecode(res.body) as Map).cast<String, dynamic>();
      } catch (_) {}
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return json;
    throw SiteError((json['error'] as String?) ?? 'HTTP ${res.statusCode}',
        status: res.statusCode);
  }
}
