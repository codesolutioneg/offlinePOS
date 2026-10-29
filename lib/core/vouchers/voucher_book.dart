import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'voucher_code.dart';

/// Why a redeem, confirm, or release was refused.
///
/// [used] means another bill already took the code, or it is held on an open
/// bill. [invalid] means the digits are not a code in this campaign.
class VoucherDecision {
  const VoucherDecision._({
    required this.ok,
    this.error,
    this.code,
    this.serial,
    this.percent,
    this.customerName,
    this.expiresLabel,
  });

  const VoucherDecision.accepted({
    required String code,
    required int serial,
    required double percent,
    String? customerName,
    String? expiresLabel,
  }) : this._(
          ok: true,
          code: code,
          serial: serial,
          percent: percent,
          customerName: customerName,
          expiresLabel: expiresLabel,
        );

  const VoucherDecision.refused(String error) : this._(ok: false, error: error);

  final bool ok;
  final String? error;
  final String? code;
  final int? serial;
  final double? percent;
  final String? customerName;
  final String? expiresLabel;
}

/// One row of the branch report.
class VoucherUse {
  const VoucherUse({
    required this.code,
    required this.serial,
    required this.status,
    required this.branchName,
    required this.customerName,
    required this.orderUuid,
    required this.heldAt,
    this.orderNo,
    this.cashier,
    this.discountAmount,
    this.usedAt,
  });

  final String code;
  final int serial;
  final String status;
  final String branchName;
  final String customerName;
  final String orderUuid;
  final String? orderNo;
  final String? cashier;
  final double? discountAmount;
  final String heldAt;
  final String? usedAt;

  Map<String, Object?> toJson() => {
        'code': code,
        'serial': serial,
        'status': status,
        'branch_name': branchName,
        'customer_name': customerName,
        'order_uuid': orderUuid,
        'order_no': orderNo,
        'cashier': cashier,
        'discount_amount': discountAmount,
        'held_at': heldAt,
        'used_at': usedAt,
      };
}

/// One inclusive span of voucher serials, as added on the admin page.
///
/// [discountId] is empty when the span still uses the book's default percent.
class VoucherSpan {
  const VoucherSpan(this.from, this.to, {this.discountId});

  final int from;
  final int to;
  final String? discountId;

  bool contains(int serial) => serial >= from && serial <= to;
}

/// A named percent the owner can attach to a span of voucher numbers.
class VoucherDiscount {
  const VoucherDiscount({required this.id, required this.name, required this.percent});

  final String id;
  final String name;
  final double percent;
}

/// The voucher book for every branch.
///
/// A code has no row until a till redeems it. Redeem and the mark-used are the
/// same locked step, so two branches cannot both be told the code is free.
/// A hold that nobody pays or cancels is given back after [holdFor], which is
/// how a till that died mid-bill does not burn the voucher forever.
class VoucherBook {
  VoucherBook._(this._file, this._root);

  final File _file;
  final Map<String, dynamic> _root;
  Future<void> _queue = Future<void>.value();

  /// How long an unpaid hold blocks the code. After that, another till may take it.
  Duration holdFor = const Duration(hours: 12);

  /// The clock the hold expiry is measured on. Tests move it.
  DateTime Function() clock = () => DateTime.now().toUtc();

  static Future<VoucherBook> open(File file) async {
    Map<String, dynamic> root;
    if (await file.exists()) {
      final decoded = jsonDecode(await file.readAsString());
      root = (decoded as Map).cast<String, dynamic>();
    } else {
      root = {
        'percent': 15,
        'adminKey': null,
        'branches': <dynamic>[],
        'vouchers': <String, dynamic>{},
        'ranges': <dynamic>[],
      };
    }
    root.putIfAbsent('vouchers', () => <String, dynamic>{});
    root.putIfAbsent('branches', () => <dynamic>[]);
    root.putIfAbsent('discounts', () => <dynamic>[]);
    // Older files stored one pair of bounds. A missing list means that pair;
    // an empty list means nobody has added numbers yet.
    if (root['ranges'] is! List) {
      final from = (root['rangeFrom'] as num?)?.toInt();
      final to = (root['rangeTo'] as num?)?.toInt();
      root['ranges'] = (from != null && to != null && to >= from)
          ? [
              {'from': from, 'to': to}
            ]
          : <dynamic>[];
    }
    final book = VoucherBook._(file, root);
    if (book._rekeyPlainNumbers()) await book._save();
    return book;
  }

  /// The number spans a cashier may redeem. Empty until someone adds one.
  List<VoucherSpan> get ranges => [
        for (final item in (_root['ranges'] as List))
          if (item is Map)
            VoucherSpan(
              (item['from'] as num?)?.toInt() ?? 0,
              (item['to'] as num?)?.toInt() ?? 0,
              discountId: item['discount'] as String?,
            ),
      ];

  List<VoucherDiscount> get discounts => [
        for (final item in (_root['discounts'] as List))
          if (item is Map)
            VoucherDiscount(
              id: '${item['id'] ?? ''}',
              name: '${item['name'] ?? ''}',
              percent: (item['percent'] as num?)?.toDouble() ?? percent,
            ),
      ];

  double get percent => (_root['percent'] as num?)?.toDouble() ?? 15;

  /// The percent a cashier gets for [serial]. The first span that contains it
  /// wins. A span with no type, or a type that was removed, uses [percent].
  double percentFor(int serial) {
    for (final span in ranges) {
      if (!span.contains(serial)) continue;
      return percentOf(span);
    }
    return percent;
  }

  double percentOf(VoucherSpan span) {
    final id = span.discountId;
    if (id == null || id.isEmpty) return percent;
    for (final discount in discounts) {
      if (discount.id == id) return discount.percent;
    }
    return percent;
  }

  String? discountName(VoucherSpan span) {
    final id = span.discountId;
    if (id == null || id.isEmpty) return null;
    for (final discount in discounts) {
      if (discount.id == id) return discount.name;
    }
    return null;
  }
  String? get adminKey => _root['adminKey'] as String?;

  List<Map<String, dynamic>> get branches => [
        for (final b in (_root['branches'] as List))
          (b as Map).cast<String, dynamic>(),
      ];

  /// First-run keys. Existing keys are left as they are, so a restart does not
  /// unpair the tills that already pasted them.
  Future<void> ensureBootstrap({
    String? adminKey,
    String? branchKey,
    String branchName = 'Local',
  }) {
    return _tx(() async {
      _root['adminKey'] ??= adminKey ?? _newKey();
      final list = _root['branches'] as List;
      if (list.isEmpty) {
        list.add({
          'name': branchName,
          'key': branchKey ?? _newKey(),
        });
      }
      await _save();
    });
  }

  Future<({String name, String key})> addBranch(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('A branch needs a name');
    }
    return _tx(() async {
      final key = _newKey();
      (_root['branches'] as List).add({'name': trimmed, 'key': key});
      await _save();
      return (name: trimmed, key: key);
    });
  }

  bool adminMatches(String key) => key.isNotEmpty && key == adminKey;

  /// Remember a named percent. The same name updates its percent instead of
  /// adding a second row. Returns 'discount' when the name or percent is unusable.
  Future<String?> addDiscount(String name, double percent) {
    return _tx(() async {
      final trimmed = name.trim();
      if (trimmed.isEmpty || trimmed.length > 40) return 'discount';
      if (percent <= 0 || percent > 100) return 'discount';
      final list = _root['discounts'] as List;
      for (final item in list) {
        if (item is Map && '${item['name'] ?? ''}'.trim() == trimmed) {
          item['percent'] = percent;
          await _save();
          return null;
        }
      }
      final n = ((_root['discountSeq'] as num?)?.toInt() ?? 0) + 1;
      _root['discountSeq'] = n;
      list.add({'id': 'd$n', 'name': trimmed, 'percent': percent});
      await _save();
      return null;
    });
  }

  /// Drop the discount type at [index]. Spans that used it go back to [percent].
  Future<void> removeDiscount(int index) {
    return _tx(() async {
      final list = _root['discounts'] as List;
      if (index < 0 || index >= list.length) return;
      final id = (list[index] as Map)['id'];
      list.removeAt(index);
      for (final item in (_root['ranges'] as List)) {
        if (item is Map && item['discount'] == id) item.remove('discount');
      }
      await _save();
    });
  }

  /// Remember that serials [from] through [to] may be redeemed. The same pair
  /// added twice is kept once. [discountId] attaches a type; null keeps the default.
  /// Returns 'invalid' or 'discount' when the pair cannot be used.
  Future<String?> addRange(int from, int to, {String? discountId}) {
    return _tx(() async {
      if (from < 1 || to < from || to > 1000000) return 'invalid';
      if (discountId != null && discountId.isNotEmpty && !_knownDiscount(discountId)) {
        return 'discount';
      }
      final list = _root['ranges'] as List;
      for (final item in list) {
        if (item is Map &&
            (item['from'] as num?)?.toInt() == from &&
            (item['to'] as num?)?.toInt() == to) {
          _writeDiscount(item, discountId);
          await _save();
          return null;
        }
      }
      final row = <String, Object?>{'from': from, 'to': to};
      _writeDiscount(row, discountId);
      list.add(row);
      await _save();
      return null;
    });
  }

  /// Point the span at [index] at [discountId]. An empty id restores the default.
  Future<String?> setRangeDiscount(int index, String? discountId) {
    return _tx(() async {
      final list = _root['ranges'] as List;
      if (index < 0 || index >= list.length || list[index] is! Map) return 'invalid';
      if (discountId != null && discountId.isNotEmpty && !_knownDiscount(discountId)) {
        return 'discount';
      }
      _writeDiscount(list[index] as Map, discountId);
      await _save();
      return null;
    });
  }

  /// Drop the span at [index]. Numbers already used stay in the report.
  Future<void> removeRange(int index) {
    return _tx(() async {
      final list = _root['ranges'] as List;
      if (index < 0 || index >= list.length) return;
      list.removeAt(index);
      await _save();
    });
  }

  bool covers(int serial) => ranges.any((span) => span.contains(serial));

  /// The cheque a customer claims with a phone number. The same phone keeps the
  /// same number. A phone that already paid is refused.
  Future<VoucherDecision> claimOffer(String rawPhone) {
    return _tx(() async {
      if (_offerClosed()) return const VoucherDecision.refused('expired');
      final phone = _normalizePhone(rawPhone);
      if (phone == null) return const VoucherDecision.refused('name');
      final existingKey = _keyForPhone(phone);
      final existing = existingKey == null ? null : _vouchers[existingKey];
      if (existing != null) {
        final status = existing['status'] as String? ?? '';
        if (status == 'used') return const VoucherDecision.refused('used');
        final serial = (existing['serial'] as num?)?.toInt() ?? 0;
        return _offerDecision(serial, phone);
      }
      final serial = _nextFreeSerial();
      if (serial == null) return const VoucherDecision.refused('empty');
      final code = VoucherCode.issue(serial).code;
      _vouchers[code] = {
        'serial': serial,
        'status': 'issued',
        'claimed': true,
        'branch_name': '',
        'customer_name': phone,
        'order_uuid': '',
        'order_no': null,
        'cashier': null,
        'discount_amount': null,
        'held_at': clock().toIso8601String(),
        'used_at': null,
      };
      await _save();
      return _offerDecision(serial, phone);
    });
  }

  VoucherDecision _offerDecision(int serial, String phone) {
    return VoucherDecision.accepted(
      code: '$serial',
      serial: serial,
      percent: percentFor(serial),
      customerName: phone,
      expiresLabel: _expiresLabel(),
    );
  }

  /// Reserve [rawCode] for [orderUuid]. The same order may reserve it again.
  Future<VoucherDecision> redeem({
    required String branchKey,
    required String rawCode,
    required String customerName,
    required String orderUuid,
    String? orderNo,
    String? cashier,
  }) {
    return _tx(() async {
      final branch = _branchFor(branchKey);
      if (branch == null) return const VoucherDecision.refused('not_configured');
      _markBranchSeen(branch);
      if (_offerClosed()) return const VoucherDecision.refused('expired');
      final parsed = VoucherCode.parse(rawCode);
      if (parsed == null || !covers(parsed.serial)) {
        return const VoucherDecision.refused('invalid');
      }
      final typedName = customerName.trim();
      final vouchers = _vouchers;
      final existingKey = _keyFor(parsed.serial);
      final existing = existingKey == null ? null : vouchers[existingKey];
      if (existing != null) {
        final status = existing['status'] as String? ?? 'held';
        final owner = existing['order_uuid'] as String?;
        final stored = '${existing['customer_name'] ?? ''}'.trim();
        final name = typedName.isEmpty ? stored : typedName;
        if (status == 'used') return const VoucherDecision.refused('used');
        if (name.isEmpty) return const VoucherDecision.refused('name');
        final take = status == 'issued' || owner == orderUuid || _holdExpired(existing);
        if (!take) return const VoucherDecision.refused('used');
        existing['status'] = 'held';
        existing['customer_name'] = name;
        existing['order_uuid'] = orderUuid;
        existing['branch_name'] = branch['name'];
        existing['held_at'] = clock().toIso8601String();
        if (orderNo != null) existing['order_no'] = orderNo;
        if (cashier != null) existing['cashier'] = cashier;
        await _save();
        return VoucherDecision.accepted(
          code: parsed.code,
          serial: parsed.serial,
          percent: percentFor(parsed.serial),
          customerName: name,
          expiresLabel: _expiresLabel(),
        );
      }
      if (typedName.isEmpty) return const VoucherDecision.refused('name');
      if (existingKey != null && existingKey != parsed.code) {
        vouchers.remove(existingKey);
      }
      vouchers[parsed.code] = {
        'serial': parsed.serial,
        'status': 'held',
        'branch_name': branch['name'],
        'customer_name': typedName,
        'order_uuid': orderUuid,
        'order_no': orderNo,
        'cashier': cashier,
        'discount_amount': null,
        'held_at': clock().toIso8601String(),
        'used_at': null,
      };
      await _save();
      return VoucherDecision.accepted(
        code: parsed.code,
        serial: parsed.serial,
        percent: percentFor(parsed.serial),
      );
    });
  }

  /// The bill was paid. A used code stays used, including after a refund.
  Future<VoucherDecision> confirm({
    required String branchKey,
    required String rawCode,
    required String orderUuid,
    double? discountAmount,
    String? orderNo,
  }) {
    return _tx(() async {
      final branch = _branchFor(branchKey);
      if (branch == null) {
        return const VoucherDecision.refused('not_configured');
      }
      _markBranchSeen(branch);
      final parsed = VoucherCode.parse(rawCode);
      if (parsed == null) return const VoucherDecision.refused('invalid');
      final row = _rowFor(parsed.serial);
      if (row == null) return const VoucherDecision.refused('invalid');
      if (row['order_uuid'] != orderUuid) {
        return const VoucherDecision.refused('used');
      }
      if (row['status'] != 'used') {
        row['status'] = 'used';
        row['used_at'] = clock().toIso8601String();
        if (discountAmount != null) row['discount_amount'] = discountAmount;
        if (orderNo != null) row['order_no'] = orderNo;
      }
      await _save();
      return VoucherDecision.accepted(
        code: parsed.code,
        serial: parsed.serial,
        percent: percent,
      );
    });
  }

  /// The bill was cancelled before it was paid, so the code can be used again.
  /// A code already marked used is left used.
  Future<VoucherDecision> release({
    required String branchKey,
    required String rawCode,
    required String orderUuid,
  }) {
    return _tx(() async {
      final branch = _branchFor(branchKey);
      if (branch == null) {
        return const VoucherDecision.refused('not_configured');
      }
      _markBranchSeen(branch);
      final parsed = VoucherCode.parse(rawCode);
      if (parsed == null) return const VoucherDecision.refused('invalid');
      final vouchers = _vouchers;
      final key = _keyFor(parsed.serial);
      final row = key == null ? null : vouchers[key];
      if (row == null) {
        return VoucherDecision.accepted(
          code: parsed.code,
          serial: parsed.serial,
          percent: percent,
        );
      }
      if (row['order_uuid'] != orderUuid) {
        return const VoucherDecision.refused('used');
      }
      if (row['status'] == 'used') return const VoucherDecision.refused('used');
      if (row['claimed'] == true) {
        row['status'] = 'issued';
        row['order_uuid'] = '';
        row['order_no'] = null;
        row['cashier'] = null;
        row['branch_name'] = '';
        await _save();
        return VoucherDecision.accepted(
          code: parsed.code,
          serial: parsed.serial,
          percent: percent,
          customerName: '${row['customer_name'] ?? ''}',
        );
      }
      vouchers.remove(key);
      await _save();
      return VoucherDecision.accepted(
        code: parsed.code,
        serial: parsed.serial,
        percent: percent,
      );
    });
  }

  Future<List<VoucherUse>> report() {
    return _tx(() async {
      final rows = <VoucherUse>[];
      for (final entry in _vouchers.entries) {
        final row = entry.value;
        rows.add(VoucherUse(
          code: entry.key,
          serial: (row['serial'] as num?)?.toInt() ?? 0,
          status: row['status'] as String? ?? 'held',
          branchName: row['branch_name'] as String? ?? '',
          customerName: row['customer_name'] as String? ?? '',
          orderUuid: row['order_uuid'] as String? ?? '',
          orderNo: row['order_no'] as String?,
          cashier: row['cashier'] as String?,
          discountAmount: (row['discount_amount'] as num?)?.toDouble(),
          heldAt: row['held_at'] as String? ?? '',
          usedAt: row['used_at'] as String?,
        ));
      }
      rows.sort((a, b) => b.heldAt.compareTo(a.heldAt));
      return rows;
    });
  }

  /// Older files stored the check-digit form (serial 1 was "18"). The cashier
  /// types the serial itself now, so those rows are filed under that number.
  bool _rekeyPlainNumbers() {
    final raw = _root['vouchers'];
    if (raw is! Map) return false;
    final next = <String, Map<String, dynamic>>{};
    var changed = false;
    for (final entry in raw.entries) {
      if (entry.value is! Map) continue;
      final row = (entry.value as Map).cast<String, dynamic>();
      final serial = (row['serial'] as num?)?.toInt();
      final key = (serial != null && serial > 0) ? '$serial' : '${entry.key}';
      if (key != '${entry.key}') changed = true;
      final previous = next[key];
      if (previous != null) changed = true;
      if (previous != null && previous['status'] == 'used' && row['status'] != 'used') {
        continue;
      }
      next[key] = row;
    }
    if (!changed) return false;
    _root['vouchers'] = next;
    return true;
  }

  String? _keyFor(int serial) {
    final vouchers = _vouchers;
    if (vouchers.containsKey('$serial')) return '$serial';
    for (final entry in vouchers.entries) {
      if ((entry.value['serial'] as num?)?.toInt() == serial) return entry.key;
    }
    return null;
  }

  Map<String, dynamic>? _rowFor(int serial) {
    final key = _keyFor(serial);
    if (key == null) return null;
    return _vouchers[key];
  }

  bool _offerClosed() => clock().toUtc().isAfter(_deadline());

  DateTime _deadline() {
    final raw = _root['offerExpires'] as String? ?? '2026-12-30';
    final parsed = DateTime.tryParse(raw) ?? DateTime.utc(2026, 12, 30);
    return DateTime.utc(parsed.year, parsed.month, parsed.day, 23, 59, 59);
  }

  String _expiresLabel() {
    final day = _deadline();
    final dd = day.day.toString().padLeft(2, '0');
    final mm = day.month.toString().padLeft(2, '0');
    return '$dd/$mm/${day.year}';
  }

  String? _normalizePhone(String raw) {
    var digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('00')) digits = digits.substring(2);
    if (digits.startsWith('20') && digits.length >= 12) digits = digits.substring(2);
    if (digits.startsWith('0')) digits = digits.substring(1);
    if (digits.length < 8 || digits.length > 12) return null;
    return digits;
  }

  String? _keyForPhone(String phone) {
    String? usedKey;
    for (final entry in _vouchers.entries) {
      if (_normalizePhone('${entry.value['customer_name'] ?? ''}') != phone) continue;
      final status = entry.value['status'] as String? ?? '';
      if (status != 'used') return entry.key;
      usedKey = entry.key;
    }
    return usedKey;
  }

  int? _nextFreeSerial() {
    final taken = <int>{
      for (final row in _vouchers.values)
        if ((row['serial'] as num?) != null) (row['serial'] as num).toInt(),
    };
    final spans = [...ranges]..sort((a, b) => a.from.compareTo(b.from));
    for (final span in spans) {
      for (var n = span.from; n <= span.to; n++) {
        if (!taken.contains(n)) return n;
      }
    }
    return null;
  }

  bool _knownDiscount(String id) => discounts.any((discount) => discount.id == id);

  void _writeDiscount(Map item, String? discountId) {
    if (discountId == null || discountId.isEmpty) {
      item.remove('discount');
    } else {
      item['discount'] = discountId;
    }
  }

  /// The till pasted this branch key and reached the server.
  Future<String?> hello(String branchKey) {
    return _tx(() async {
      final branch = _branchFor(branchKey);
      if (branch == null) return 'not_configured';
      _markBranchSeen(branch);
      await _save();
      return null;
    });
  }

  Map<String, dynamic>? _branchFor(String key) {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return null;
    for (final branch in branches) {
      if (branch['key'] == trimmed) return branch;
    }
    return null;
  }

  void _markBranchSeen(Map<String, dynamic> branch) {
    branch['last_seen'] = clock().toIso8601String();
  }

  bool branchConnected(Map<String, dynamic> branch) {
    if ('${branch['last_seen'] ?? ''}'.trim().isNotEmpty) return true;
    final name = '${branch['name'] ?? ''}';
    if (name.isEmpty) return false;
    for (final row in _vouchers.values) {
      if ('${row['branch_name'] ?? ''}' == name) return true;
    }
    return false;
  }

  Map<String, Map<String, dynamic>> get _vouchers {
    final raw = _root['vouchers'];
    if (raw is Map<String, Map<String, dynamic>>) return raw;
    final cast = <String, Map<String, dynamic>>{};
    if (raw is Map) {
      for (final entry in raw.entries) {
        cast['${entry.key}'] = (entry.value as Map).cast<String, dynamic>();
      }
    }
    _root['vouchers'] = cast;
    return cast;
  }

  bool _holdExpired(Map<String, dynamic> row) {
    final at = DateTime.tryParse(row['held_at'] as String? ?? '');
    if (at == null) return true;
    return clock().isAfter(at.toUtc().add(holdFor));
  }

  Future<T> _tx<T>(Future<T> Function() body) {
    final run = _queue.then((_) => body());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _save() async {
    final text = const JsonEncoder.withIndent('  ').convert(_root);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(text);
    if (await _file.exists()) await _file.delete();
    await tmp.rename(_file.path);
  }

  static String _newKey() {
    final bytes = List<int>.generate(24, (_) => Random.secure().nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
