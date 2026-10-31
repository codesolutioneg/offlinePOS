import 'dart:convert';
import 'dart:io';

import 'code128.dart';
import 'offer_page.dart';
import 'voucher_book.dart';
import 'voucher_code.dart';

/// Serves the voucher book on [port]. Binds to loopback unless [address] says
/// otherwise: a local trial is not reachable from the shop network.
Future<HttpServer> serveVouchers(
  VoucherBook book, {
  InternetAddress? address,
  int port = 8787,
}) async {
  final server = await HttpServer.bind(
    address ?? InternetAddress.loopbackIPv4,
    port,
  );
  server.listen((request) async {
    try {
      await _handle(book, request);
    } catch (_) {
      try {
        await _json(request, HttpStatus.internalServerError, {
          'ok': false,
          'error': 'server',
        });
      } catch (_) {}
    }
  });
  return server;
}

Future<void> _handle(VoucherBook book, HttpRequest request) async {
  final path = request.uri.path;
  if (request.method == 'GET' && path == '/offer') {
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..headers.set('cache-control', 'no-store')
      ..write(offerPageHtml());
    await request.response.close();
    return;
  }
  if (request.method == 'GET' && path == '/offer/cheque.jpg') {
    return _asset(request, 'cheque.jpg', ContentType('image', 'jpeg'));
  }
  if (request.method == 'GET' && path == '/offer/logo.png') {
    return _asset(request, 'logo.png', ContentType('image', 'png'));
  }
  if (request.method == 'GET' && path == '/offer/barcode.svg') {
    final code = request.uri.queryParameters['code'] ?? '';
    final parsed = VoucherCode.parse(code);
    request.response
      ..statusCode = parsed == null ? HttpStatus.badRequest : HttpStatus.ok
      ..headers.contentType = ContentType('image', 'svg+xml')
      ..write(parsed == null ? '' : code128Svg(parsed.code));
    await request.response.close();
    return;
  }
  if (request.method == 'POST' && path == '/v1/offer') {
    final body = await _body(request);
    final decision = await book.claimOffer('${body['phone'] ?? ''}');
    return _json(request, decision.ok ? HttpStatus.ok : HttpStatus.conflict, {
      'ok': decision.ok,
      'error': decision.error,
      'code': decision.code,
      'serial': decision.serial,
      'percent': decision.percent,
      'phone': decision.customerName,
      'expires': decision.expiresLabel,
    });
  }
  if (request.method == 'GET' && path == '/health') {
    return _json(request, HttpStatus.ok, {
      'ok': true,
      'percent': book.percent,
      'ranges': [
        for (final span in book.ranges)
          {'from': span.from, 'to': span.to, 'percent': book.percentOf(span)},
      ],
    });
  }
  if (request.method == 'GET' && path == '/admin') {
    final key = request.uri.queryParameters['key'] ?? '';
    if (key.isEmpty) {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(_adminLoginHtml());
      await request.response.close();
      return;
    }
    if (!book.adminMatches(key)) {
      return _json(request, HttpStatus.unauthorized, {'ok': false, 'error': 'admin'});
    }
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(_adminHtml(book, key, request.uri.queryParameters['error']));
    await request.response.close();
    return;
  }
  if (request.method == 'POST' && path == '/admin/ranges') {
    final body = await _body(request);
    final key = '${body['key'] ?? ''}';
    if (!book.adminMatches(key)) {
      return _json(request, HttpStatus.unauthorized, {'ok': false, 'error': 'admin'});
    }
    final from = int.tryParse('${body['from'] ?? ''}'.trim()) ?? 0;
    final to = int.tryParse('${body['to'] ?? ''}'.trim()) ?? 0;
    final error = await book.addRange(from, to, discountId: _blank(body['discount']));
    return _redirect(request, key, error);
  }
  if (request.method == 'POST' && path == '/admin/discounts') {
    final body = await _body(request);
    final key = '${body['key'] ?? ''}';
    if (!book.adminMatches(key)) {
      return _json(request, HttpStatus.unauthorized, {'ok': false, 'error': 'admin'});
    }
    final percent = double.tryParse('${body['percent'] ?? ''}'.trim());
    final error = await book.addDiscount('${body['name'] ?? ''}', percent ?? 0);
    return _redirect(request, key, error);
  }
  if (request.method == 'POST' && path == '/admin/discounts/remove') {
    final body = await _body(request);
    final key = '${body['key'] ?? ''}';
    if (!book.adminMatches(key)) {
      return _json(request, HttpStatus.unauthorized, {'ok': false, 'error': 'admin'});
    }
    final index = int.tryParse('${body['index'] ?? ''}') ?? -1;
    await book.removeDiscount(index);
    return _redirect(request, key, null);
  }
  if (request.method == 'POST' && path == '/admin/ranges/discount') {
    final body = await _body(request);
    final key = '${body['key'] ?? ''}';
    if (!book.adminMatches(key)) {
      return _json(request, HttpStatus.unauthorized, {'ok': false, 'error': 'admin'});
    }
    final index = int.tryParse('${body['index'] ?? ''}') ?? -1;
    final error = await book.setRangeDiscount(index, _blank(body['discount']));
    return _redirect(request, key, error);
  }
  if (request.method == 'POST' && path == '/admin/ranges/remove') {
    final body = await _body(request);
    final key = '${body['key'] ?? ''}';
    if (!book.adminMatches(key)) {
      return _json(request, HttpStatus.unauthorized, {'ok': false, 'error': 'admin'});
    }
    final index = int.tryParse('${body['index'] ?? ''}') ?? -1;
    await book.removeRange(index);
    return _redirect(request, key, null);
  }
  if (request.method == 'POST' && path == '/admin/branches/add') {
    final body = await _body(request);
    final key = '${body['key'] ?? ''}';
    if (!book.adminMatches(key)) {
      return _json(request, HttpStatus.unauthorized, {'ok': false, 'error': 'admin'});
    }
    final name = '${body['name'] ?? ''}'.trim();
    if (name.isEmpty) return _redirect(request, key, 'branch');
    await book.addBranch(name);
    return _redirect(request, key, null);
  }
  if (request.method == 'GET' && path == '/v1/admin/overview') {
    if (!_admin(book, request)) {
      return _json(request, HttpStatus.unauthorized, {'ok': false, 'error': 'admin'});
    }
    final rows = await book.report();
    return _json(request, HttpStatus.ok, {
      'ok': true,
      'percent': book.percent,
      'discounts': [
        for (final discount in book.discounts)
          {'id': discount.id, 'name': discount.name, 'percent': discount.percent},
      ],
      'ranges': [
        for (final span in book.ranges)
          {
            'from': span.from,
            'to': span.to,
            'discount_id': span.discountId,
            'percent': book.percentOf(span),
          },
      ],
      'branches': [
        for (final branch in book.branches)
          {
            'name': branch['name'],
            'key': branch['key'],
            'last_seen': branch['last_seen'],
            'connected': book.branchConnected(branch),
          },
      ],
      'rows': [for (final row in rows) row.toJson()],
    });
  }
  if (request.method == 'POST' && path == '/v1/admin/ranges') {
    if (!_admin(book, request)) {
      return _json(request, HttpStatus.unauthorized, {'ok': false, 'error': 'admin'});
    }
    final body = await _body(request);
    final from = int.tryParse('${body['from'] ?? ''}'.trim()) ?? 0;
    final to = int.tryParse('${body['to'] ?? ''}'.trim()) ?? 0;
    final error = await book.addRange(from, to, discountId: _blank(body['discount_id']));
    if (error != null) {
      return _json(request, HttpStatus.badRequest, {'ok': false, 'error': error});
    }
    return _json(request, HttpStatus.ok, {'ok': true});
  }
  if (request.method == 'POST' && path == '/v1/admin/discounts') {
    if (!_admin(book, request)) {
      return _json(request, HttpStatus.unauthorized, {'ok': false, 'error': 'admin'});
    }
    final body = await _body(request);
    final percent = double.tryParse('${body['percent'] ?? ''}'.trim()) ??
        (body['percent'] as num?)?.toDouble();
    final error = await book.addDiscount('${body['name'] ?? ''}', percent ?? 0);
    if (error != null) {
      return _json(request, HttpStatus.badRequest, {'ok': false, 'error': error});
    }
    return _json(request, HttpStatus.ok, {'ok': true});
  }
  if (request.method == 'POST' && path == '/v1/admin/discounts/remove') {
    if (!_admin(book, request)) {
      return _json(request, HttpStatus.unauthorized, {'ok': false, 'error': 'admin'});
    }
    final body = await _body(request);
    final index = int.tryParse('${body['index'] ?? ''}') ?? -1;
    await book.removeDiscount(index);
    return _json(request, HttpStatus.ok, {'ok': true});
  }
  if (request.method == 'POST' && path == '/v1/admin/ranges/discount') {
    if (!_admin(book, request)) {
      return _json(request, HttpStatus.unauthorized, {'ok': false, 'error': 'admin'});
    }
    final body = await _body(request);
    final index = int.tryParse('${body['index'] ?? ''}') ?? -1;
    final error = await book.setRangeDiscount(index, _blank(body['discount_id']));
    if (error != null) {
      return _json(request, HttpStatus.badRequest, {'ok': false, 'error': error});
    }
    return _json(request, HttpStatus.ok, {'ok': true});
  }
  if (request.method == 'POST' && path == '/v1/admin/ranges/remove') {
    if (!_admin(book, request)) {
      return _json(request, HttpStatus.unauthorized, {'ok': false, 'error': 'admin'});
    }
    final body = await _body(request);
    final index = int.tryParse('${body['index'] ?? ''}') ?? -1;
    await book.removeRange(index);
    return _json(request, HttpStatus.ok, {'ok': true});
  }
  if (request.method == 'GET' && (path == '/report' || path == '/admin/report')) {
    if (!_admin(book, request)) {
      return _json(request, HttpStatus.unauthorized, {'ok': false, 'error': 'admin'});
    }
    final rows = await book.report();
    if (path == '/report') {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(_reportHtml(book, rows));
      await request.response.close();
      return;
    }
    return _json(request, HttpStatus.ok, {
      'ok': true,
      'rows': [for (final row in rows) row.toJson()],
    });
  }
  if (request.method == 'POST' && path == '/admin/branches') {
    if (!_admin(book, request)) {
      return _json(request, HttpStatus.unauthorized, {'ok': false, 'error': 'admin'});
    }
    final body = await _body(request);
    final created = await book.addBranch('${body['name'] ?? ''}');
    return _json(request, HttpStatus.ok, {
      'ok': true,
      'name': created.name,
      'key': created.key,
    });
  }
  if (request.method != 'POST') {
    return _json(request, HttpStatus.notFound, {'ok': false, 'error': 'not_found'});
  }
  final branchKey = request.headers.value('x-branch-key') ?? '';
  if (path == '/v1/hello') {
    final error = await book.hello(branchKey);
    return _json(
      request,
      error == null ? HttpStatus.ok : HttpStatus.unauthorized,
      {'ok': error == null, 'error': error},
    );
  }
  final body = await _body(request);
  final VoucherDecision decision;
  switch (path) {
    case '/v1/redeem':
      decision = await book.redeem(
        branchKey: branchKey,
        rawCode: '${body['code'] ?? ''}',
        customerName: '${body['customer_name'] ?? ''}',
        orderUuid: '${body['order_uuid'] ?? ''}',
        orderNo: body['order_no'] as String?,
        cashier: body['cashier'] as String?,
      );
    case '/v1/confirm':
      decision = await book.confirm(
        branchKey: branchKey,
        rawCode: '${body['code'] ?? ''}',
        orderUuid: '${body['order_uuid'] ?? ''}',
        discountAmount: (body['discount_amount'] as num?)?.toDouble(),
        orderNo: body['order_no'] as String?,
      );
    case '/v1/release':
      decision = await book.release(
        branchKey: branchKey,
        rawCode: '${body['code'] ?? ''}',
        orderUuid: '${body['order_uuid'] ?? ''}',
      );
    default:
      return _json(request, HttpStatus.notFound, {'ok': false, 'error': 'not_found'});
  }
  return _json(request, decision.ok ? HttpStatus.ok : HttpStatus.conflict, {
    'ok': decision.ok,
    'error': decision.error,
    'code': decision.code,
    'serial': decision.serial,
    'percent': decision.percent,
    'customer_name': decision.customerName,
    'expires': decision.expiresLabel,
  });
}

Future<void> _asset(HttpRequest request, String name, ContentType type) async {
  final relative = 'lib/core/vouchers/assets/$name';
  final local = File(relative);
  final file = local.existsSync() ? local : File('/app/$relative');
  if (!await file.exists()) {
    return _json(request, HttpStatus.notFound, {'ok': false, 'error': 'not_found'});
  }
  request.response
    ..statusCode = HttpStatus.ok
    ..headers.contentType = type
    ..add(await file.readAsBytes());
  await request.response.close();
}

bool _admin(VoucherBook book, HttpRequest request) {
  final header = request.headers.value('x-admin-key') ?? '';
  final query = request.uri.queryParameters['key'] ?? '';
  return book.adminMatches(header.isNotEmpty ? header : query);
}

Future<Map<String, dynamic>> _body(HttpRequest request) async {
  final text = await utf8.decoder.bind(request).join();
  if (text.trim().isEmpty) return const {};
  final type = request.headers.contentType?.mimeType ?? '';
  if (type == 'application/x-www-form-urlencoded') {
    return Uri.splitQueryString(text);
  }
  final decoded = jsonDecode(text);
  if (decoded is Map) return decoded.cast<String, dynamic>();
  return const {};
}

Future<void> _redirect(HttpRequest request, String key, String? error) async {
  final query = StringBuffer('key=${Uri.encodeQueryComponent(key)}');
  if (error != null) query.write('&error=$error');
  request.response
    ..statusCode = HttpStatus.seeOther
    ..headers.set(HttpHeaders.locationHeader, '/admin?$query')
    ..write('');
  await request.response.close();
}

Future<void> _json(HttpRequest request, int status, Map<String, Object?> body) async {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  await request.response.close();
}

String _reportHtml(VoucherBook book, List<VoucherUse> rows) {
  final body = rows.map((row) {
    final amount = row.discountAmount == null
        ? ''
        : row.discountAmount!.toStringAsFixed(2);
    return '<tr>'
        '<td>${_esc(row.code)}</td>'
        '<td>${_esc(row.status)}</td>'
        '<td>${_esc(row.customerName)}</td>'
        '<td>${_esc(row.branchName)}</td>'
        '<td>${_esc(row.cashier ?? '')}</td>'
        '<td>${_esc(row.orderNo ?? '')}</td>'
        '<td>${_esc(row.heldAt)}</td>'
        '<td>${_esc(row.usedAt ?? '')}</td>'
        '<td>$amount</td>'
        '</tr>';
  }).join();
  return '''
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Vouchers</title>
<style>
body { font-family: sans-serif; margin: 24px; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #ccc; padding: 6px 8px; text-align: left; }
th { background: #f4f4f4; }
</style></head><body>
<h1>Vouchers</h1>
<p>الخصم ${book.percent.toStringAsFixed(0)}%.</p>
<p>النطاقات: ${_esc(_spanText(book))}</p>
<table>
<tr><th>Code</th><th>Status</th><th>Customer</th><th>Branch</th><th>Cashier</th><th>Order</th><th>Held</th><th>Used</th><th>Discount</th></tr>
$body
</table>
</body></html>
''';
}

String _spanText(VoucherBook book) {
  if (book.ranges.isEmpty) return 'لا توجد أرقام بعد';
  return book.ranges.map((span) => '${span.from}–${span.to}').join(' ، ');
}

String _adminLoginHtml() => '''
<!DOCTYPE html>
<html lang="ar" dir="rtl"><head><meta charset="utf-8"><title>الفاوتشرات</title>
<style>body { font-family: sans-serif; margin: 24px; } input, button { font-size: 16px; padding: 6px; }</style>
</head><body>
<h1>الفاوتشرات</h1>
<form method="get" action="/admin">
<label>مفتاح الإدارة <input name="key" autofocus required></label>
<button>دخول</button>
</form>
</body></html>
''';

String _adminHtml(VoucherBook book, String key, String? error) {
  final hidden = '<input type="hidden" name="key" value="${_esc(key)}">';
  final spans = StringBuffer();
  final list = book.ranges;
  if (list.isEmpty) {
    spans.write('<p>لسه مفيش أرقام. اكتب من وإلى ثم إضافة.</p>');
  }
  for (var i = 0; i < list.length; i++) {
    final span = list[i];
    final sample = VoucherCode.issue(span.from).code;
    final options = StringBuffer('<option value="">الخصم الافتراضي ${book.percent.toStringAsFixed(0)}%</option>');
    for (final discount in book.discounts) {
      final selected = discount.id == span.discountId ? ' selected' : '';
      options.write(
        '<option value="${_esc(discount.id)}"$selected>${_esc(discount.name)} ${discount.percent.toStringAsFixed(0)}%</option>',
      );
    }
    spans.write(
      '<li>من ${span.from} إلى ${span.to} — ${book.percentOf(span).toStringAsFixed(0)}% — الكاشير يكتب مثلاً ${_esc(sample)} '
      '<form method="post" action="/admin/ranges/discount" style="display:inline">'
      '$hidden<input type="hidden" name="index" value="$i">'
      '<select name="discount">$options</select>'
      '<button>حفظ الخصم</button></form> '
      '<form method="post" action="/admin/ranges/remove" style="display:inline">'
      '$hidden<input type="hidden" name="index" value="$i">'
      '<button>حذف</button></form></li>',
    );
  }
  final discountRows = StringBuffer();
  final types = book.discounts;
  for (var i = 0; i < types.length; i++) {
    final discount = types[i];
    discountRows.write(
      '<li>${_esc(discount.name)} — ${discount.percent.toStringAsFixed(0)}% '
      '<form method="post" action="/admin/discounts/remove" style="display:inline">'
      '$hidden<input type="hidden" name="index" value="$i">'
      '<button>حذف</button></form></li>',
    );
  }
  final branches = StringBuffer();
  for (final branch in book.branches) {
    branches.write(
      '<li>${_esc('${branch['name']}')}: <code>${_esc('${branch['key']}')}</code></li>',
    );
  }
  final warning = (error == 'range' || error == 'invalid')
      ? '<p>النطاق غير مقبول. ابدأ من 1، ويكون «إلى» أكبر من «من».</p>'
      : error == 'discount'
          ? '<p>نوع الخصم غير مقبول. الاسم مطلوب، والنسبة أكبر من صفر وحتى 100.</p>'
          : error == 'branch'
              ? '<p>اكتب اسم الفرع.</p>'
              : '';
  return '''
<!DOCTYPE html>
<html lang="ar" dir="rtl"><head><meta charset="utf-8"><title>الفاوتشرات</title>
<style>
body { font-family: sans-serif; margin: 24px; max-width: 720px; }
input, button { font-size: 16px; padding: 6px; }
code { background: #f4f4f4; padding: 2px 6px; }
li { margin: 8px 0; }
</style></head><body>
<h1>الفاوتشرات</h1>
<p>من غير نوع خصم، الفاتورة تاخد ${book.percent.toStringAsFixed(0)}%.</p>
$warning
<h2>أنواع الخصم</h2>
<form method="post" action="/admin/discounts">
$hidden
<label>الاسم <input name="name" required></label>
<label>النسبة <input name="percent" inputmode="decimal" required></label>
<button>إضافة نوع</button>
</form>
<ul>$discountRows</ul>
<h2>إضافة أرقام</h2>
<form method="post" action="/admin/ranges">
$hidden
<label>من <input name="from" inputmode="numeric" required></label>
<label>إلى <input name="to" inputmode="numeric" required></label>
<button>إضافة</button>
</form>
<ul>$spans</ul>
<p>الأرقام هنا أصل الفاوتشر. الكاشير يكتب نفس الرقم ومعاه رقم التأكيد في الآخر.</p>
<h2>الفروع</h2>
<p>الصق مفتاح الفرع مرة واحدة في إعدادات كل أجهزة الفرع.</p>
<ul>$branches</ul>
<form method="post" action="/admin/branches/add">
$hidden
<label>اسم فرع جديد <input name="name" required></label>
<button>إضافة فرع</button>
</form>
<p><a href="/report?key=${Uri.encodeQueryComponent(key)}">تقرير الاستخدام</a></p>
</body></html>
''';
}

String? _blank(Object? value) {
  final text = '${value ?? ''}'.trim();
  return text.isEmpty ? null : text;
}

String _esc(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
