/// A voucher number the cashier types as printed: 1 is 1.
class VoucherCode {
  const VoucherCode({required this.serial, required this.code});

  final int serial;

  /// Digits the cashier should type, with no leading zeros.
  final String code;

  static const int defaultFrom = 1;
  static const int defaultTo = 30000;

  /// The number printed for [serial].
  static VoucherCode issue(int serial) {
    if (serial <= 0) {
      throw ArgumentError.value(serial, 'serial', 'must be at least 1');
    }
    return VoucherCode(serial: serial, code: '$serial');
  }

  /// What the cashier typed, or null when it is not a voucher number.
  ///
  /// Spaces and dashes are ignored. Leading zeros do not make a second number:
  /// 1 and 01 are the same serial.
  static VoucherCode? parse(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty || digits.length > 7) return null;
    final serial = int.tryParse(digits);
    if (serial == null || serial <= 0 || serial > 1000000) return null;
    return VoucherCode(serial: serial, code: '$serial');
  }

  static bool inRange(int serial, {required int from, required int to}) =>
      serial >= from && serial <= to;
}
