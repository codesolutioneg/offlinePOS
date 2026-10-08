/// Dishflow Flash SALES SUMMARY math (thermal / PDF / screen).
///
/// 1) Amount Sales = TOTAL + DISCOUNTS − TAX (14%)
/// 2) TAX         = extracted from (payments + discount) inclusive ÷ 1.14
/// 3) DISCOUNTS   = −check discount
/// 4) TOTAL        = payments (after discount)
library;

const double kFlashTaxFactor = 1.14;

class FlashSalesSummaryMath {
  /// Sum of payments (what was paid after discount, tax-inclusive).
  final double payments;

  /// Sum of check-level discounts only (Dishflow `discountAmount`).
  final double discounts;

  const FlashSalesSummaryMath({
    required this.payments,
    required this.discounts,
  });

  /// Payments + discount (tax extraction base).
  double get salesPlusDiscount =>
      (payments + discounts).clamp(0.0, double.infinity);

  /// 14% VAT extracted from [salesPlusDiscount] (tax-inclusive).
  double get tax {
    final s = salesPlusDiscount;
    if (s <= 0.0001) return 0.0;
    return s - s / kFlashTaxFactor;
  }

  /// Before tax on (payments + discount).
  double get netBeforeTax {
    final s = salesPlusDiscount;
    if (s <= 0.0001) return 0.0;
    return s / kFlashTaxFactor;
  }

  /// Final total = payments (after discount).
  double get total =>
      (salesPlusDiscount - discounts).clamp(0.0, double.infinity);

  /// Amount Sales = TOTAL + DISCOUNTS − TAX.
  double get amountSales =>
      (total + discounts - tax).clamp(0.0, double.infinity);
}
