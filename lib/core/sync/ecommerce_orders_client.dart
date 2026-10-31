import 'dart:convert';
import 'dart:io';

import '../../domain/ecommerce_order.dart';
import 'dishflow_firestore_sender.dart';

/// Reads and claims Dishflow `ecommerce_orders` over the Firestore REST API.
///
/// Same credentials as the owner mirror ([SettingsStore] project id + API key).
/// No `cloud_firestore` dependency — desktop tills stay on HTTPS only.
class EcommerceOrdersClient {
  EcommerceOrdersClient({HttpClient Function()? openClient})
      : _openClient = openClient ?? HttpClient.new;

  final HttpClient Function() _openClient;

  /// Active store orders (`pending` / `received`), optionally narrowed to [branchId].
  Future<List<EcommerceOrder>> listActive({
    required String projectId,
    required String apiKey,
    String? branchId,
  }) async {
    final url = Uri.parse(
      'https://firestore.googleapis.com/v1/projects/$projectId'
      '/databases/(default)/documents:runQuery?key=$apiKey',
    );
    final body = {
      'structuredQuery': {
        'from': [
          {'collectionId': 'ecommerce_orders'}
        ],
        'where': {
          'fieldFilter': {
            'field': {'fieldPath': 'status'},
            'op': 'IN',
            'value': {
              'arrayValue': {
                'values': [
                  {'stringValue': 'pending'},
                  {'stringValue': 'received'},
                ]
              }
            },
          }
        },
        'limit': 80,
      },
    };
    final client = _openClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.postUrl(url);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.add(utf8.encode(jsonEncode(body)));
      final res = await req.close().timeout(const Duration(seconds: 30));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw StateError('ecommerce_orders query HTTP ${res.statusCode}: $text');
      }
      final decoded = jsonDecode(text);
      if (decoded is! List) return const [];
      final out = <EcommerceOrder>[];
      for (final row in decoded) {
        if (row is! Map) continue;
        final doc = row['document'];
        if (doc is! Map) continue;
        final name = '${doc['name'] ?? ''}';
        final id = name.split('/').last;
        if (id.isEmpty) continue;
        final fields = decodeFields(doc['fields']);
        final order = EcommerceOrderParser.fromMap(id, fields);
        if (branchId != null &&
            branchId.isNotEmpty &&
            order.branchId != null &&
            order.branchId!.isNotEmpty &&
            order.branchId != branchId) {
          continue;
        }
        out.add(order);
      }
      out.sort((a, b) {
        final ac = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bc = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bc.compareTo(ac);
      });
      return out;
    } finally {
      client.close(force: true);
    }
  }

  /// Claim a pending order for [cashierId]. Soft re-claim allowed for same cashier.
  Future<bool> tryClaim({
    required String projectId,
    required String apiKey,
    required String orderId,
    required String cashierId,
    String? cashierName,
  }) async {
    final existing = await _get(
      projectId: projectId,
      apiKey: apiKey,
      orderId: orderId,
    );
    if (existing == null) return false;
    final status = existing.status;
    final lockedBy = (existing.receivedBy ?? '').trim();
    if (status == 'received' && lockedBy == cashierId) return true;
    if (status != 'pending') return false;

    await _patch(
      projectId: projectId,
      apiKey: apiKey,
      orderId: orderId,
      fields: {
        'status': 'received',
        'receivedAt': DateTime.now().toUtc().toIso8601String(),
        'receivedBy': cashierId,
        if (cashierName != null && cashierName.isNotEmpty)
          'receivedByName': cashierName,
      },
    );
    return true;
  }

  Future<bool> markCompleted({
    required String projectId,
    required String apiKey,
    required String orderId,
  }) async {
    try {
      await _patch(
        projectId: projectId,
        apiKey: apiKey,
        orderId: orderId,
        fields: {
          'status': 'completed',
          'completedAt': DateTime.now().toUtc().toIso8601String(),
        },
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<EcommerceOrder?> _get({
    required String projectId,
    required String apiKey,
    required String orderId,
  }) async {
    final url = Uri.parse(
      'https://firestore.googleapis.com/v1/projects/$projectId'
      '/databases/(default)/documents/ecommerce_orders/$orderId?key=$apiKey',
    );
    final client = _openClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(url);
      final res = await req.close().timeout(const Duration(seconds: 20));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode == 404) return null;
      if (res.statusCode != 200) {
        throw StateError('ecommerce_orders get HTTP ${res.statusCode}: $text');
      }
      final doc = jsonDecode(text);
      if (doc is! Map) return null;
      return EcommerceOrderParser.fromMap(orderId, decodeFields(doc['fields']));
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _patch({
    required String projectId,
    required String apiKey,
    required String orderId,
    required Map<String, dynamic> fields,
  }) async {
    final masks = fields.keys.map((k) => 'updateMask.fieldPaths=$k').join('&');
    final url = Uri.parse(
      'https://firestore.googleapis.com/v1/projects/$projectId'
      '/databases/(default)/documents/ecommerce_orders/$orderId?key=$apiKey&$masks',
    );
    final encoded = {
      for (final e in fields.entries)
        e.key: DishflowFirestoreSender.encodeValue(e.value),
    };
    final client = _openClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.patchUrl(url);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.add(utf8.encode(jsonEncode({'fields': encoded})));
      final res = await req.close().timeout(const Duration(seconds: 20));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw StateError('ecommerce_orders patch HTTP ${res.statusCode}: $text');
      }
    } finally {
      client.close(force: true);
    }
  }

  /// Decode a Firestore REST `fields` map into plain Dart values.
  static Map<String, dynamic> decodeFields(Object? raw) {
    if (raw is! Map) return {};
    return {
      for (final e in raw.entries) '${e.key}': decodeValue(e.value),
    };
  }

  static Object? decodeValue(Object? raw) {
    if (raw is! Map) return raw;
    if (raw.containsKey('nullValue')) return null;
    if (raw.containsKey('booleanValue')) return raw['booleanValue'] == true;
    if (raw.containsKey('integerValue')) {
      return int.tryParse('${raw['integerValue']}') ?? 0;
    }
    if (raw.containsKey('doubleValue')) {
      final v = raw['doubleValue'];
      if (v is num) return v.toDouble();
      return double.tryParse('$v') ?? 0.0;
    }
    if (raw.containsKey('stringValue')) return raw['stringValue']?.toString();
    if (raw.containsKey('timestampValue')) {
      return DateTime.tryParse('${raw['timestampValue']}');
    }
    if (raw.containsKey('arrayValue')) {
      final values = (raw['arrayValue'] as Map?)?['values'];
      if (values is! List) return const [];
      return [for (final v in values) decodeValue(v)];
    }
    if (raw.containsKey('mapValue')) {
      return decodeFields((raw['mapValue'] as Map?)?['fields']);
    }
    return raw;
  }
}

/// Parses a plain (decoded) Firestore map into [EcommerceOrder].
class EcommerceOrderParser {
  static EcommerceOrder fromMap(String id, Map<String, dynamic> m) {
    final itemsRaw = m['items'];
    final items = <EcommerceOrderItem>[];
    if (itemsRaw is List) {
      for (final raw in itemsRaw) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final modsRaw = item['modifiers'] ?? item['selected_modifiers'] ?? [];
        final mods = <EcommerceOrderModifier>[];
        if (modsRaw is List) {
          for (final mr in modsRaw) {
            if (mr is! Map) continue;
            final mm = Map<String, dynamic>.from(mr);
            mods.add(EcommerceOrderModifier(
              name: '${mm['option_name'] ?? mm['name'] ?? mm['modifier_name'] ?? ''}',
              priceExtra: _num(mm['price_extra']),
            ));
          }
        }
        final qty = _num(item['quantity']).clamp(0.001, 9999).toDouble();
        final unit = _num(item['price_unit'] ??
            item['unit_price'] ??
            (qty > 0 ? _num(item['total_price']) / qty : 0));
        items.add(EcommerceOrderItem(
          name: '${item['name'] ?? item['name_ar'] ?? 'Item'}',
          quantity: qty,
          unitPrice: unit,
          productId: _int(item['product_id'] ?? item['product_template_id']),
          notes: _blank('${item['notes'] ?? ''}'),
          modifiers: mods,
        ));
      }
    }
    return EcommerceOrder(
      id: id,
      status: '${m['status'] ?? 'pending'}',
      items: items,
      orderNumber: _blank(
          '${m['orderNumber'] ?? m['order_number'] ?? m['ecommerceOrderNumber'] ?? ''}'),
      customerName: _blank('${m['customer_name'] ?? m['customerName'] ?? ''}'),
      customerPhone: _blank('${m['customer_phone'] ?? m['customerPhone'] ?? ''}'),
      deliveryAddress: _blank(
          '${m['delivery_address'] ?? m['deliveryAddress'] ?? ''}'),
      orderType: _blank('${m['order_type'] ?? m['orderType'] ?? ''}'),
      branchId: _blank('${m['branchId'] ?? m['branch_id'] ?? ''}'),
      branchName: _blank('${m['branchName'] ?? m['branch_name'] ?? ''}'),
      deliveryFee: _num(m['deliveryFee'] ?? m['delivery_fee']),
      serviceFee: _num(m['serviceFee'] ?? m['service_fee']),
      discount: _num(m['discount'] ?? m['discountAmount']),
      totalAmount: _num(m['totalAmount'] ?? m['total_amount'] ?? m['amount']),
      dishflowOrderId:
          _blank('${m['dishflowOrderId'] ?? m['dishflow_order_id'] ?? ''}'),
      receivedBy: _blank('${m['receivedBy'] ?? m['received_by'] ?? ''}'),
      createdAt: m['createdAt'] is DateTime
          ? m['createdAt'] as DateTime
          : DateTime.tryParse('${m['createdAt'] ?? ''}'),
      raw: m,
    );
  }

  static double _num(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse('$v') ?? 0;
  }

  static int? _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v');
  }

  static String? _blank(String s) {
    final t = s.trim();
    return t.isEmpty ? null : t;
  }
}
