import 'package:offline_pos/core/auth/pin_hasher.dart';

/// Synchronous stand-in for widget tests.
///
/// The real KDF resolves on an isolate, which never completes under the widget
/// test binding's controlled clock, and a UI test should not be paying 100 ms a
/// verification anyway. The interface exists exactly so this can be substituted.
class FakePinHasher implements PinHasher {
  @override
  Future<String> hash(String pin, String saltB64) async => 'h:$saltB64:$pin';

  @override
  Future<bool> verify(String pin, String saltB64, String expectedB64) async =>
      await hash(pin, saltB64) == expectedB64;
}
