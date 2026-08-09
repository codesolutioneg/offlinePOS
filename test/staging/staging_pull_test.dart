// Drives the REAL puller through the REAL sender against a REAL Odoo build.
// Skipped unless STAGING_URL is provided.
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/odoo_sender.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';
import 'package:offline_pos/core/sync/http_post.dart';

void main() {
  const url = String.fromEnvironment('STAGING_URL');
  const db = String.fromEnvironment('STAGING_DB');
  const login = String.fromEnvironment('STAGING_LOGIN');
  const pw = String.fromEnvironment('STAGING_PASSWORD');

  test('real staging catalogue pull returns products', () async {
    if (url.isEmpty) {
      // ignore: avoid_print
      print('SKIPPED: no STAGING_URL');
      return;
    }
    final sender = OdooSender(baseUrl: Uri.parse(url), db: db, post: httpPost);
    await sender.authenticate(login, pw);
    final puller = OdooPuller(call: sender.callKw);
    final pull = await puller.pull();
    // ignore: avoid_print
    print('CATALOGUE products=${pull.products.length} categories=${pull.categories.length} usable=${pull.isUsable}');
    expect(pull.products.length, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
