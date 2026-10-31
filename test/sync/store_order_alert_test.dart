import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/store_order_alert.dart';

void main() {
  test('first snapshot is silent baseline', () {
    final w = StoreOrderWatchState();
    expect(w.observe(['a', 'b']), isEmpty);
    expect(w.ready, isTrue);
    expect(w.known, {'a', 'b'});
  });

  test('later snapshot surfaces only new ids', () {
    final w = StoreOrderWatchState();
    w.observe(['a']);
    expect(w.observe(['a', 'b']), {'b'});
    expect(w.observe(['a', 'b']), isEmpty);
    expect(w.observe(['b']), isEmpty);
    expect(w.observe(['b', 'c', 'd']), {'c', 'd'});
  });

  test('reset clears baseline', () {
    final w = StoreOrderWatchState();
    w.observe(['a']);
    w.reset();
    expect(w.ready, isFalse);
    expect(w.observe(['a']), isEmpty);
  });
}
