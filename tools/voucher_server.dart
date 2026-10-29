import 'dart:io';

import 'package:offline_pos/core/vouchers/voucher_book.dart';
import 'package:offline_pos/core/vouchers/voucher_code.dart';
import 'package:offline_pos/core/vouchers/voucher_http.dart';

/// Local voucher server. One process for every branch.
///
///   dart run tools/voucher_server.dart
///
/// The address the tills use is http://127.0.0.1:8787 while it runs on this
/// machine. The branch key printed on startup is what each till pastes once.
Future<void> main() async {
  final port = int.parse(Platform.environment['VOUCHER_PORT'] ?? '8787');
  final host = Platform.environment['VOUCHER_HOST'];
  final file = File('voucher-data/vouchers.json');
  await file.parent.create(recursive: true);
  final book = await VoucherBook.open(file);
  await book.ensureBootstrap(
    adminKey: Platform.environment['VOUCHER_ADMIN_KEY'],
    branchKey: Platform.environment['VOUCHER_BRANCH_KEY'],
    branchName: Platform.environment['VOUCHER_BRANCH_NAME'] ?? 'Local',
  );
  final address = host == null || host.isEmpty || host == '127.0.0.1'
      ? InternetAddress.loopbackIPv4
      : host == '0.0.0.0'
          ? InternetAddress.anyIPv4
          : InternetAddress(host);
  final server = await serveVouchers(book, address: address, port: port);
  final shown = server.address.address;
  stdout.writeln('Voucher server: http://$shown:${server.port}');
  stdout.writeln('Discount ${book.percent.toStringAsFixed(0)}%');
  final spans = book.ranges.map((span) => '${span.from}-${span.to}').join(', ');
  stdout.writeln(spans.isEmpty ? 'Ranges: none yet' : 'Ranges: $spans');
  stdout.writeln('Admin: http://$shown:${server.port}/admin?key=${book.adminKey}');
  stdout.writeln('Branches:');
  for (final branch in book.branches) {
    stdout.writeln('  ${branch['name']}: ${branch['key']}');
  }
  stdout.writeln(
    'Sample codes: ${[for (var n = 1; n <= 5; n++) VoucherCode.issue(n).code].join(', ')}',
  );
}
