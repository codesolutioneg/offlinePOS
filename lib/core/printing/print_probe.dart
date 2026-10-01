/// Where one print job ended up.
///
/// [atPrinter] is the printer the job was meant for (or its configured spare);
/// [onReceiptPrinter] is a kitchen ticket the receipt printer took because its
/// station did not answer, so it is on paper but at the till, not on the pass.
enum PrintOutcome { atPrinter, onReceiptPrinter, spooled, lost }

/// The kind of job, so a kitchen ticket and a receipt are counted apart.
enum PrintChannel { kitchen, receipt, subReceipt, kitchenVoid, bagSlip }

/// One job as the till's print path reported it, with the order it was for as it
/// stood when the paper was made: a receipt quoting another order's number or an
/// old total is the mix-up a full-day run is looking for.
class PrintRecord {
  PrintRecord({
    required this.channel,
    required this.outcome,
    this.orderUuid,
    this.orderNo,
    this.total,
    this.reference,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final PrintChannel channel;
  final PrintOutcome outcome;
  final String? orderUuid;
  final String? orderNo;
  final double? total;
  final String? reference;
  final DateTime at;
}

/// Counts print outcomes while something is listening.
///
/// A till in service never has one: the Stress Lab installs it for the length of
/// a run, because "the printer took the bytes" and "the ticket reached the pass"
/// are different answers and the run has to tell them apart.
class PrintProbe {
  final Map<PrintChannel, Map<PrintOutcome, int>> _counts = {};
  final List<PrintRecord> _records = [];

  void record(
    PrintChannel channel,
    PrintOutcome outcome, {
    String? orderUuid,
    String? orderNo,
    double? total,
    String? reference,
  }) {
    final byOutcome = _counts.putIfAbsent(channel, () => {});
    byOutcome[outcome] = (byOutcome[outcome] ?? 0) + 1;
    _records.add(
      PrintRecord(
        channel: channel,
        outcome: outcome,
        orderUuid: orderUuid,
        orderNo: orderNo,
        total: total,
        reference: reference,
      ),
    );
  }

  int count(PrintChannel channel, PrintOutcome outcome) =>
      _counts[channel]?[outcome] ?? 0;

  int total(PrintChannel channel) =>
      _counts[channel]?.values.fold<int>(0, (s, n) => s + n) ?? 0;

  /// Every job in the order it was reported.
  List<PrintRecord> get records => List.unmodifiable(_records);

  /// The jobs one order produced.
  List<PrintRecord> forOrder(String uuid) => [
    for (final r in _records)
      if (r.orderUuid == uuid) r,
  ];

  void reset() {
    _counts.clear();
    _records.clear();
  }
}
