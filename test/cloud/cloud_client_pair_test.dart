import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:offline_pos/core/cloud/cloud_client.dart';

/// A branch code pasted out of Arabic text arrives wrapped in direction marks
/// and spaces; the server must see only the code.
void main() {
  test('pairing sends the code without invisible marks or spaces', () async {
    String? sent;
    final client = CloudClient('https://reports.test', client: MockClient((r) async {
      sent = (jsonDecode(r.body) as Map)['pair_code'] as String;
      return http.Response(jsonEncode({'token': 't', 'shop': {'name': 'Shop'}}), 200,
          headers: {'content-type': 'application/json'});
    }));

    await client.pair(
      pairCode: '\u200F H1NH-Z45K-0HDX-9ZVR\u200E\n',
      deviceId: 'pos-1',
      deviceName: 'POS 1',
      appVersion: 'test',
    );

    expect(sent, 'H1NH-Z45K-0HDX-9ZVR');
  });
}
