import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'voucher_code.dart';

/// What the till is told after it asks the voucher server.
class VoucherReply {
  const VoucherReply({
    required this.ok,
    this.error,
    this.code,
    this.percent,
    this.customerName,
  });

  final bool ok;
  final String? error;
  final String? code;
  final double? percent;
  final String? customerName;

  static const unreachable = VoucherReply(ok: false, error: 'unreachable');
  static const notConfigured = VoucherReply(ok: false, error: 'not_configured');
}

/// The sentence the cashier sees for a refused voucher. English is the
/// translation key.
String voucherFailure(String? error) {
  switch (error) {
    case 'used':
      return 'This voucher was used before';
    case 'invalid':
      return 'This voucher number is not valid';
    case 'unreachable':
      return 'The voucher server is not reachable. No discount was applied.';
    case 'not_configured':
      return 'Set the branch voucher key in Settings';
    case 'name':
      return 'Enter the customer number';
    case 'expired':
      return 'This offer has ended';
    case 'empty':
      return 'No voucher numbers are left';
    default:
      return 'This voucher number is not valid';
  }
}

/// Asks the shared voucher server whether a code may discount this bill.
class VoucherClient {
  VoucherClient({
    required String baseUrl,
    required this.branchKey,
    http.Client? httpClient,
  })  : baseUrl = _trim(baseUrl),
        _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  final String baseUrl;
  final String branchKey;
  final http.Client _http;
  final bool _ownsClient;

  static const _timeout = Duration(seconds: 8);

  void close() {
    if (_ownsClient) _http.close();
  }

  /// A number that is not a voucher is refused here, before a call that could not succeed.
  Future<VoucherReply> redeem({
    required String code,
    required String customerName,
    required String orderUuid,
    String? orderNo,
    String? cashier,
  }) {
    if (VoucherCode.parse(code) == null) {
      return Future.value(const VoucherReply(ok: false, error: 'invalid'));
    }
    return _post('/v1/redeem', {
      'code': code,
      'customer_name': customerName,
      'order_uuid': orderUuid,
      'order_no': orderNo,
      'cashier': cashier,
    });
  }

  Future<VoucherReply> confirm({
    required String code,
    required String orderUuid,
    double? discountAmount,
    String? orderNo,
  }) {
    return _post('/v1/confirm', {
      'code': code,
      'order_uuid': orderUuid,
      'discount_amount': discountAmount,
      'order_no': orderNo,
    });
  }

  Future<VoucherReply> release({
    required String code,
    required String orderUuid,
  }) {
    return _post('/v1/release', {
      'code': code,
      'order_uuid': orderUuid,
    });
  }

  /// Tells the server this till is linked to the branch key.
  Future<VoucherReply> hello() => _post('/v1/hello', const {});

  Future<VoucherReply> _post(String path, Map<String, Object?> body) async {
    if (branchKey.trim().isEmpty || baseUrl.isEmpty) return VoucherReply.notConfigured;
    try {
      final response = await _http
          .post(
            Uri.parse('$baseUrl$path'),
            headers: {
              'content-type': 'application/json',
              'x-branch-key': branchKey.trim(),
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return VoucherReply.unreachable;
      final map = decoded.cast<String, dynamic>();
      return VoucherReply(
        ok: map['ok'] == true,
        error: map['error'] as String?,
        code: map['code'] as String?,
        percent: (map['percent'] as num?)?.toDouble(),
        customerName: map['customer_name'] as String?,
      );
    } on TimeoutException {
      return VoucherReply.unreachable;
    } on SocketException {
      return VoucherReply.unreachable;
    } on http.ClientException {
      return VoucherReply.unreachable;
    } on FormatException {
      return VoucherReply.unreachable;
    }
  }

  static String _trim(String url) {
    var value = url.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }
}
