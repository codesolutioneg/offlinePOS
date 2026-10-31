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
    required this.reportKeys,
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
  /// Mobile owner-app screens this account may open.
  final Set<String> reportKeys;
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
        reportKeys: {for (final k in (m['report_keys'] as List? ?? const [])) '$k'},
        active: m['active'] != false,
        lastLoginAt: DateTime.tryParse('${m['last_login_at'] ?? ''}'),
      );
}

class SiteBranch {
  const SiteBranch({
    required this.id,
    required this.name,
    this.taxConnectionId = '',
    this.devices = const [],
  });

  final String id;
  final String name;
  /// Dishflow odooConnectionId for this branch's ETA link.
  final String taxConnectionId;
  final List<SiteDevice> devices;

  bool get hasTaxLink => taxConnectionId.trim().isNotEmpty;

  factory SiteBranch.fromJson(Map<String, dynamic> m) => SiteBranch(
        id: m['id'] as String,
        name: m['name'] as String,
        taxConnectionId: (m['tax_connection_id'] as String?) ?? '',
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

class SiteVoucherDiscount {
  const SiteVoucherDiscount({required this.id, required this.name, required this.percent});

  final String id;
  final String name;
  final double percent;
}

class SiteVoucherRange {
  const SiteVoucherRange({
    required this.from,
    required this.to,
    required this.percent,
    this.discountId,
  });

  final int from;
  final int to;
  final double percent;
  final String? discountId;
}

class SiteVoucherBranch {
  const SiteVoucherBranch({
    required this.name,
    required this.key,
    this.connected = false,
    this.lastSeen,
  });

  final String name;
  final String key;
  final bool connected;
  final DateTime? lastSeen;
}

class SiteVoucherUse {
  const SiteVoucherUse({
    required this.code,
    required this.serial,
    required this.status,
    required this.branchName,
    required this.customerName,
    this.orderNo,
    this.cashier,
    this.discountAmount,
    this.heldAt,
    this.usedAt,
  });

  final String code;
  final int serial;
  final String status;
  final String branchName;
  final String customerName;
  final String? orderNo;
  final String? cashier;
  final double? discountAmount;
  final DateTime? heldAt;
  final DateTime? usedAt;
}

/// Numbers, branch keys and redemptions from the shared voucher server.
class SiteVouchers {
  const SiteVouchers({
    required this.percent,
    required this.discounts,
    required this.ranges,
    required this.branches,
    required this.rows,
  });

  final double percent;
  final List<SiteVoucherDiscount> discounts;
  final List<SiteVoucherRange> ranges;
  final List<SiteVoucherBranch> branches;
  final List<SiteVoucherUse> rows;

  factory SiteVouchers.fromJson(Map<String, dynamic> m) =>       SiteVouchers(
        percent: (m['percent'] as num?)?.toDouble() ?? 15,
        discounts: [
          for (final d in (m['discounts'] as List? ?? const []))
            if (d is Map)
              SiteVoucherDiscount(
                id: '${d['id'] ?? ''}',
                name: '${d['name'] ?? ''}',
                percent: (d['percent'] as num?)?.toDouble() ?? 0,
              ),
        ],
        ranges: [
          for (final r in (m['ranges'] as List? ?? const []))
            if (r is Map)
              SiteVoucherRange(
                from: (r['from'] as num?)?.toInt() ?? 0,
                to: (r['to'] as num?)?.toInt() ?? 0,
                percent: (r['percent'] as num?)?.toDouble() ?? (m['percent'] as num?)?.toDouble() ?? 15,
                discountId: '${r['discount_id'] ?? ''}'.isEmpty ? null : '${r['discount_id']}',
              ),
        ],
        branches: [
          for (final b in (m['branches'] as List? ?? const []))
            if (b is Map)
              SiteVoucherBranch(
                name: '${b['name'] ?? ''}',
                key: '${b['key'] ?? ''}',
                connected: b['connected'] == true,
                lastSeen: DateTime.tryParse('${b['last_seen'] ?? ''}'),
              ),
        ],
        rows: [
          for (final row in (m['rows'] as List? ?? const []))
            if (row is Map)
              SiteVoucherUse(
                code: '${row['code'] ?? ''}',
                serial: (row['serial'] as num?)?.toInt() ?? int.tryParse('${row['code'] ?? ''}') ?? 0,
                status: '${row['status'] ?? ''}',
                branchName: '${row['branch_name'] ?? ''}',
                customerName: '${row['customer_name'] ?? ''}',
                orderNo: row['order_no'] as String?,
                cashier: row['cashier'] as String?,
                discountAmount: (row['discount_amount'] as num?)?.toDouble(),
                heldAt: DateTime.tryParse('${row['held_at'] ?? ''}'),
                usedAt: DateTime.tryParse('${row['used_at'] ?? ''}'),
              ),
        ],
      );
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
    this.reportKeys,
    this.active,
  });

  final String? username;
  final String? displayName;
  final SiteRole? role;
  final String? password;
  final bool? allBranches;
  final List<String>? branchIds;
  final Set<String>? capabilities;
  final Set<String>? reportKeys;
  final bool? active;

  Map<String, Object?> toJson() => {
        'username': ?username,
        'display_name': ?displayName,
        'role': ?role?.name,
        'password': ?password,
        'all_branches': ?allBranches,
        'branch_ids': ?branchIds,
        if (capabilities != null) 'capabilities': capabilities!.toList(),
        if (reportKeys != null) 'report_keys': reportKeys!.toList(),
        'active': ?active,
      };
}

class SiteTaxIntegration {
  const SiteTaxIntegration({
    required this.id,
    this.name = '',
    this.serialNumber = '',
    this.isDefault = false,
    this.branchCode = '0',
    this.addressCountry = 'EG',
    this.addressGovernate = '',
    this.addressRegionCity = '',
    this.addressStreet = '',
    this.addressBuildingNumber = '',
    this.orderTypes = const [],
    this.hasClientId = false,
    this.hasClientSecret = false,
    this.clientId = '',
    this.clientSecret = '',
  });

  final String id;
  final String name;
  final String serialNumber;
  final bool isDefault;
  final String branchCode;
  final String addressCountry;
  final String addressGovernate;
  final String addressRegionCity;
  final String addressStreet;
  final String addressBuildingNumber;
  final List<String> orderTypes;
  final bool hasClientId;
  final bool hasClientSecret;
  final String clientId;
  final String clientSecret;

  factory SiteTaxIntegration.fromJson(Map<String, dynamic> m) =>
      SiteTaxIntegration(
        id: (m['id'] as String?) ?? '',
        name: (m['name'] as String?) ?? '',
        serialNumber: (m['serialNumber'] as String?) ?? '',
        isDefault: m['isDefault'] == true,
        branchCode: (m['branchCode'] as String?) ?? '0',
        addressCountry: (m['addressCountry'] as String?) ?? 'EG',
        addressGovernate: (m['addressGovernate'] as String?) ?? '',
        addressRegionCity: (m['addressRegionCity'] as String?) ?? '',
        addressStreet: (m['addressStreet'] as String?) ?? '',
        addressBuildingNumber: (m['addressBuildingNumber'] as String?) ?? '',
        orderTypes: [
          for (final t in (m['orderTypes'] as List? ?? const [])) '$t',
        ],
        hasClientId: m['has_client_id'] == true,
        hasClientSecret: m['has_client_secret'] == true,
        clientId: (m['clientId'] as String?) ?? '',
        clientSecret: (m['clientSecret'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'serialNumber': serialNumber,
        'isDefault': isDefault,
        'branchCode': branchCode,
        'addressCountry': addressCountry,
        'addressGovernate': addressGovernate,
        'addressRegionCity': addressRegionCity,
        'addressStreet': addressStreet,
        'addressBuildingNumber': addressBuildingNumber,
        'orderTypes': orderTypes,
        'clientId': clientId,
        'clientSecret': clientSecret,
      };

  SiteTaxIntegration copyWith({
    String? name,
    String? serialNumber,
    bool? isDefault,
    String? branchCode,
    String? addressCountry,
    String? addressGovernate,
    String? addressRegionCity,
    String? addressStreet,
    String? addressBuildingNumber,
    List<String>? orderTypes,
    String? clientId,
    String? clientSecret,
    bool? hasClientId,
    bool? hasClientSecret,
  }) =>
      SiteTaxIntegration(
        id: id,
        name: name ?? this.name,
        serialNumber: serialNumber ?? this.serialNumber,
        isDefault: isDefault ?? this.isDefault,
        branchCode: branchCode ?? this.branchCode,
        addressCountry: addressCountry ?? this.addressCountry,
        addressGovernate: addressGovernate ?? this.addressGovernate,
        addressRegionCity: addressRegionCity ?? this.addressRegionCity,
        addressStreet: addressStreet ?? this.addressStreet,
        addressBuildingNumber:
            addressBuildingNumber ?? this.addressBuildingNumber,
        orderTypes: orderTypes ?? this.orderTypes,
        hasClientId: hasClientId ?? this.hasClientId,
        hasClientSecret: hasClientSecret ?? this.hasClientSecret,
        clientId: clientId ?? this.clientId,
        clientSecret: clientSecret ?? this.clientSecret,
      );
}

class SiteTaxSettings {
  const SiteTaxSettings({
    this.connectionId = '',
    this.connectionName = '',
    this.rin = '',
    this.companyTradeName = '',
    this.activityCode = '5610',
    this.useSandbox = false,
    this.integrations = const [],
  });

  final String connectionId;
  final String connectionName;
  final String rin;
  final String companyTradeName;
  final String activityCode;
  final bool useSandbox;
  final List<SiteTaxIntegration> integrations;

  factory SiteTaxSettings.fromJson(Map<String, dynamic> m) => SiteTaxSettings(
        connectionId: (m['connection_id'] as String?) ?? '',
        connectionName: (m['connection_name'] as String?) ?? '',
        rin: (m['rin'] as String?) ?? '',
        companyTradeName: (m['company_trade_name'] as String?) ?? '',
        activityCode: (m['activity_code'] as String?) ?? '5610',
        useSandbox: m['use_sandbox'] == true,
        integrations: [
          for (final r in (m['integrations'] as List? ?? const []))
            if (r is Map)
              SiteTaxIntegration.fromJson(r.cast<String, dynamic>()),
        ],
      );
}

class SiteTaxPaymentStat {
  const SiteTaxPaymentStat({
    required this.paymentMethod,
    required this.count,
    required this.amount,
  });

  final String paymentMethod;
  final int count;
  final double amount;
}

class SiteTaxSummary {
  const SiteTaxSummary({
    required this.count,
    required this.totalAmount,
    required this.sessions,
    this.byPayment = const [],
    this.submittedCount = 0,
    this.submittedAmount = 0,
    this.grossCount = 0,
    this.grossAmount = 0,
    this.differenceCount = 0,
    this.differenceAmount = 0,
  });

  final int count;
  final double totalAmount;
  final int sessions;
  final List<SiteTaxPaymentStat> byPayment;
  final int submittedCount;
  final double submittedAmount;
  final int grossCount;
  final double grossAmount;
  final int differenceCount;
  final double differenceAmount;

  factory SiteTaxSummary.fromJson(Map<String, dynamic> m) => SiteTaxSummary(
        count: (m['count'] as num?)?.toInt() ?? 0,
        totalAmount: (m['total_amount'] as num?)?.toDouble() ?? 0,
        sessions: (m['sessions'] as num?)?.toInt() ?? 0,
        byPayment: [
          for (final r in (m['by_payment'] as List? ?? const []))
            if (r is Map)
              SiteTaxPaymentStat(
                paymentMethod: (r['payment_method'] as String?) ?? '',
                count: (r['count'] as num?)?.toInt() ?? 0,
                amount: (r['amount'] as num?)?.toDouble() ?? 0,
              ),
        ],
        submittedCount: (m['submitted_count'] as num?)?.toInt() ??
            (m['count'] as num?)?.toInt() ??
            0,
        submittedAmount: (m['submitted_amount'] as num?)?.toDouble() ??
            (m['total_amount'] as num?)?.toDouble() ??
            0,
        grossCount: (m['gross_count'] as num?)?.toInt() ?? 0,
        grossAmount: (m['gross_amount'] as num?)?.toDouble() ?? 0,
        differenceCount: (m['difference_count'] as num?)?.toInt() ?? 0,
        differenceAmount: (m['difference_amount'] as num?)?.toDouble() ?? 0,
      );
}

class SiteTaxInvoice {
  const SiteTaxInvoice({
    required this.id,
    this.firebaseDocId,
    this.orderNumber = '',
    this.sessionId = '',
    this.paymentMethod = '',
    this.amount = 0,
    this.status = '',
    this.etaUuid,
    this.etaLongId,
    this.etaSubmittedAt,
  });

  final String id;
  final String? firebaseDocId;
  final String orderNumber;
  final String sessionId;
  final String paymentMethod;
  final double amount;
  final String status;
  final String? etaUuid;
  final String? etaLongId;
  final DateTime? etaSubmittedAt;

  factory SiteTaxInvoice.fromJson(Map<String, dynamic> m) => SiteTaxInvoice(
        id: m['id'] as String,
        firebaseDocId: m['firebase_doc_id'] as String?,
        orderNumber: (m['order_number'] as String?) ?? '',
        sessionId: (m['session_id'] as String?) ?? '',
        paymentMethod: (m['payment_method'] as String?) ?? '',
        amount: (m['amount'] as num?)?.toDouble() ?? 0,
        status: (m['status'] as String?) ?? '',
        etaUuid: m['eta_uuid'] as String?,
        etaLongId: m['eta_long_id'] as String?,
        etaSubmittedAt: DateTime.tryParse('${m['eta_submitted_at'] ?? ''}'),
      );
}

class SiteTaxConnection {
  const SiteTaxConnection({
    required this.connectionId,
    required this.name,
    this.pending = 0,
    this.submitted = 0,
  });

  final String connectionId;
  final String name;
  final int pending;
  final int submitted;
}

class SiteTaxPending {
  const SiteTaxPending({
    required this.id,
    this.firebaseDocId,
    this.orderNumber = '',
    this.sessionId = '',
    this.businessDateKey = '',
    this.paymentMethod = '',
    this.amount = 0,
    this.status = 'pending',
    this.timestamp,
  });

  final String id;
  final String? firebaseDocId;
  final String orderNumber;
  final String sessionId;
  final String businessDateKey;
  final String paymentMethod;
  final double amount;
  final String status;
  final DateTime? timestamp;

  factory SiteTaxPending.fromJson(Map<String, dynamic> m) => SiteTaxPending(
        id: m['id'] as String,
        firebaseDocId: m['firebase_doc_id'] as String?,
        orderNumber: (m['order_number'] as String?) ?? '',
        sessionId: (m['session_id'] as String?) ?? '',
        businessDateKey: (m['business_date_key'] as String?) ?? '',
        paymentMethod: (m['payment_method'] as String?) ?? '',
        amount: (m['amount'] as num?)?.toDouble() ?? 0,
        status: (m['status'] as String?) ?? 'pending',
        timestamp: DateTime.tryParse('${m['timestamp'] ?? ''}'),
      );
}

class SiteTaxPendingPage {
  const SiteTaxPendingPage({
    required this.pending,
    this.byPayment = const [],
  });

  final List<SiteTaxPending> pending;
  final List<SiteTaxPaymentStat> byPayment;

  factory SiteTaxPendingPage.fromJson(Map<String, dynamic> m) => SiteTaxPendingPage(
        pending: [
          for (final r in (m['pending'] as List? ?? const []))
            if (r is Map) SiteTaxPending.fromJson(r.cast<String, dynamic>()),
        ],
        byPayment: [
          for (final r in (m['by_payment'] as List? ?? const []))
            if (r is Map)
              SiteTaxPaymentStat(
                paymentMethod: (r['payment_method'] as String?) ?? '',
                count: (r['count'] as num?)?.toInt() ?? 0,
                amount: (r['amount'] as num?)?.toDouble() ?? 0,
              ),
        ],
      );
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

  Future<void> setBranchTaxConnection(String id, String taxConnectionId) =>
      _call('PATCH', '/api/branches/$id', {
        'tax_connection_id': taxConnectionId,
      });

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

  Future<SiteVouchers> vouchers() async =>
      SiteVouchers.fromJson(await _call('GET', '/api/vouchers'));

  Future<void> addVoucherDiscount(String name, double percent) =>
      _call('POST', '/api/vouchers/discounts', {'name': name, 'percent': percent});

  Future<void> removeVoucherDiscount(int index) =>
      _call('POST', '/api/vouchers/discounts/remove', {'index': index});

  Future<void> addVoucherRange(int from, int to, {String? discountId}) =>
      _call('POST', '/api/vouchers/ranges', {
        'from': from,
        'to': to,
        'discount_id': ?discountId,
      });

  Future<void> removeVoucherRange(int index) =>
      _call('POST', '/api/vouchers/ranges/remove', {'index': index});

  Future<void> setVoucherRangeDiscount(int index, String? discountId) =>
      _call('POST', '/api/vouchers/ranges/discount', {
        'index': index,
        'discount_id': discountId ?? '',
      });

  Future<String> addVoucherBranch(String name) async =>
      (await _call('POST', '/api/vouchers/branches', {'name': name}))['key'] as String;

  // ── Tax upload (owner) ─────────────────────────────────────────────────

  Future<SiteTaxSettings> taxSettings() async {
    final body = await _call('GET', '/api/tax/settings');
    final s = (body['settings'] as Map?)?.cast<String, dynamic>();
    if (s == null) {
      return SiteTaxSettings(
        connectionId: (body['default_connection_id'] as String?) ??
            'yFsBtvlradoAkKSascZ3',
        connectionName: 'Balkans Nasr City',
      );
    }
    return SiteTaxSettings.fromJson(s);
  }

  Future<SiteTaxSettings> taxSettingsSync() async {
    final body = await _call('POST', '/api/tax/settings/sync');
    return SiteTaxSettings.fromJson(
      ((body['settings'] as Map?) ?? const {}).cast<String, dynamic>(),
    );
  }

  Future<SiteTaxSettings> taxSettingsSave({
    required String connectionId,
    required String rin,
    required String companyTradeName,
    required String activityCode,
    required bool useSandbox,
    required List<SiteTaxIntegration> integrations,
  }) async {
    final body = await _call('PUT', '/api/tax/settings', {
      'connection_id': connectionId,
      'rin': rin,
      'company_trade_name': companyTradeName,
      'activity_code': activityCode,
      'use_sandbox': useSandbox,
      'integrations': [for (final i in integrations) i.toJson()],
    });
    return SiteTaxSettings.fromJson(
      ((body['settings'] as Map?) ?? const {}).cast<String, dynamic>(),
    );
  }

  Future<({int scanned, int inserted, int updated})> taxMigrate(
      {String? connectionId}) async {
    final body = await _call('POST', '/api/tax/migrate', {
      if (connectionId != null) 'connection_id': connectionId,
    });
    return (
      scanned: (body['scanned'] as num?)?.toInt() ?? 0,
      inserted: (body['inserted'] as num?)?.toInt() ?? 0,
      updated: (body['updated'] as num?)?.toInt() ?? 0,
    );
  }

  Future<SiteTaxSummary> taxSummary({
    String? connectionId,
    DateTime? from,
    DateTime? to,
    String? session,
    String? payment,
    String? status,
  }) async {
    final body = await _call('GET', '/api/tax/summary', null, {
      if (connectionId != null) 'connection_id': connectionId,
      if (from != null) 'from': from.toUtc().toIso8601String(),
      if (to != null) 'to': to.toUtc().toIso8601String(),
      if (session != null) 'session': session,
      if (payment != null) 'payment': payment,
      if (status != null) 'status': status,
    });
    return SiteTaxSummary.fromJson(body);
  }

  Future<({int total, List<SiteTaxInvoice> invoices})> taxInvoices({
    String? connectionId,
    DateTime? from,
    DateTime? to,
    String? session,
    String? payment,
    String? status,
    int limit = 100,
    int offset = 0,
  }) async {
    final body = await _call('GET', '/api/tax/invoices', null, {
      if (connectionId != null) 'connection_id': connectionId,
      if (from != null) 'from': from.toUtc().toIso8601String(),
      if (to != null) 'to': to.toUtc().toIso8601String(),
      if (session != null) 'session': session,
      if (payment != null) 'payment': payment,
      if (status != null) 'status': status,
      'limit': '$limit',
      'offset': '$offset',
    });
    return (
      total: (body['total'] as num?)?.toInt() ?? 0,
      invoices: [
        for (final r in (body['invoices'] as List? ?? const []))
          if (r is Map)
            SiteTaxInvoice.fromJson(r.cast<String, dynamic>()),
      ],
    );
  }

  Future<List<SiteTaxConnection>> taxConnections() async {
    final body = await _call('GET', '/api/tax/connections');
    return [
      for (final r in (body['connections'] as List? ?? const []))
        if (r is Map)
          SiteTaxConnection(
            connectionId: (r['connection_id'] as String?) ?? '',
            name: (r['name'] as String?) ?? '',
            pending: (r['pending'] as num?)?.toInt() ?? 0,
            submitted: (r['submitted'] as num?)?.toInt() ?? 0,
          ),
    ];
  }

  Future<({int scanned, int inserted, int updated})> taxSyncPending(
      {String? connectionId}) async {
    final body = await _call('POST', '/api/tax/sync-pending', {
      if (connectionId != null) 'connection_id': connectionId,
    });
    return (
      scanned: (body['scanned'] as num?)?.toInt() ?? 0,
      inserted: (body['inserted'] as num?)?.toInt() ?? 0,
      updated: (body['updated'] as num?)?.toInt() ?? 0,
    );
  }

  Future<SiteTaxPendingPage> taxPending({
    String? connectionId,
    String? session,
    String? payment,
    int limit = 500,
  }) async {
    final body = await _call('GET', '/api/tax/pending', null, {
      if (connectionId != null) 'connection_id': connectionId,
      if (session != null) 'session': session,
      if (payment != null) 'payment': payment,
      'limit': '$limit',
    });
    return SiteTaxPendingPage.fromJson(body);
  }

  Future<({int accepted, int rejected, String batchId})> taxSubmit({
    required List<String> invoiceIds,
    String? connectionId,
  }) async {
    final body = await _call('POST', '/api/tax/submit', {
      'invoice_ids': invoiceIds,
      if (connectionId != null) 'connection_id': connectionId,
    });
    return (
      accepted: (body['accepted'] as num?)?.toInt() ?? 0,
      rejected: (body['rejected'] as num?)?.toInt() ?? 0,
      batchId: (body['batch_id'] as String?) ?? '',
    );
  }

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
