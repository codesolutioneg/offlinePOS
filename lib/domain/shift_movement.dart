import 'shift.dart';

/// One cash movement together with the shift it happened in.
///
/// A [CashMovement] carries no actor of its own, so a report that spans several
/// shifts would otherwise not be able to say who paid the money out.
class ShiftMovement {
  const ShiftMovement({
    required this.movement,
    required this.shiftId,
    required this.cashierId,
  });

  final CashMovement movement;
  final String shiftId;

  /// The cashier the shift was opened by.
  final String cashierId;
}
