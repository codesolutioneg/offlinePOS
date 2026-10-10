import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/lan/lan_transport.dart';
import 'package:offline_pos/features/settings/lan_settings_screen.dart';

void main() {
  String failure(Object e) => 'Join failed: $e\n#0 stack';

  test('a locked door says how long to wait', () {
    final key = joinFailureMessage(
        failure(const HttpException('429 from http://10.0.0.2/lan/join: {}')))!;
    expect(key, contains('${LanProtocol.joinLockout.inMinutes} minutes'));
  });

  test('a refused PIN says so instead of the raw answer', () {
    final key = joinFailureMessage(
        failure(const HttpException('403 from http://10.0.0.2/lan/join: {}')))!;
    expect(key, startsWith('Wrong PIN'));
  });

  test('an unreachable primary keeps its own message', () {
    final key = joinFailureMessage(failure(TimeoutException('x')))!;
    expect(key, startsWith('Could not reach the primary'));
  });

  test('anything else falls back to the raw first line', () {
    expect(joinFailureMessage(failure(const FormatException('bad'))), isNull);
    expect(joinFailureMessage('Fingerprints...: StateError'), isNull);
  });
}
