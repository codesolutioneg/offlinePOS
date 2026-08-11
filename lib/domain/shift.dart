/// A cash movement into or out of the drawer during a shift.
class CashMovement {
  const CashMovement({
    required this.type, // 'in' or 'out'
    required this.amount,
    required this.at,
    this.reason = '',
    this.category,
  });

  final String type;
  final double amount;
  final String reason;
  final DateTime at;

  /// For a paid-out (an expense), which bucket it belongs to (Transport, Food,
  /// Supplies, ...). Null for a plain drawer movement or a paid-in.
  final String? category;

  Map<String, dynamic> toMap() => {
        'type': type,
        'amount': amount,
        'reason': reason,
        'category': category,
        'at': at.toIso8601String(),
      };

  factory CashMovement.fromMap(Map<String, dynamic> m) => CashMovement(
        type: (m['type'] ?? 'in') as String,
        amount: (m['amount'] as num).toDouble(),
        reason: (m['reason'] ?? '') as String,
        category: m['category'] as String?,
        at: DateTime.parse(m['at'] as String),
      );
}

/// A cashier's shift on the till: when it opened, the opening float, the cash
/// movements during it, and (once closed) the counted cash.
class Shift {
  Shift({
    required this.id,
    required this.openedAt,
    required this.openingFloat,
    required this.cashierId,
    this.closedAt,
    this.closingCounted,
    List<CashMovement>? movements,
  }) : movements = movements ?? [];

  final String id;
  final DateTime openedAt;
  DateTime? closedAt;
  final double openingFloat;
  final String cashierId;
  final List<CashMovement> movements;
  double? closingCounted;

  bool get isOpen => closedAt == null;
  double get cashIn =>
      movements.where((m) => m.type == 'in').fold(0.0, (s, m) => s + m.amount);
  double get cashOut =>
      movements.where((m) => m.type == 'out').fold(0.0, (s, m) => s + m.amount);
}

/// The X (mid-shift) / Z (close) figures for a shift.
class ShiftSummary {
  const ShiftSummary({
    required this.openingFloat,
    required this.cashIn,
    required this.cashOut,
    required this.salesCount,
    required this.salesTotal,
    required this.cashSales,
    this.countedCash,
  });

  final double openingFloat;
  final double cashIn;
  final double cashOut;
  final int salesCount;

  /// All takings in the window, every tender. This is turnover, not drawer cash.
  final double salesTotal;

  /// The cash portion of those takings: what actually landed in the drawer. Card
  /// and other non-cash tenders are in [salesTotal] but never here.
  final double cashSales;
  final double? countedCash;

  /// What the drawer should hold: the float, the cash taken, and any cash paid
  /// in, less anything paid out. Card sales are deliberately excluded.
  double get expectedCash => openingFloat + cashSales + cashIn - cashOut;

  /// Counted minus expected, once a count has been entered.
  double? get variance =>
      countedCash == null ? null : countedCash! - expectedCash;
}
