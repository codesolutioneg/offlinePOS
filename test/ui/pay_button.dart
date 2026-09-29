import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The button that takes the order to payment.
///
/// A screen tall enough for the order action bar settles from its Settle key and
/// drops the big Pay button under the bill; a short one keeps the Pay button.
Finder findPay() {
  final settle = find.byKey(const Key('order-action-settle'));
  return settle.evaluate().isNotEmpty ? settle : find.byKey(const Key('pay'));
}
