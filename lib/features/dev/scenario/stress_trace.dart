import '../../../domain/delivery.dart';
import '../../../domain/order.dart';
import '../stress_note.dart';

/// One thing that happened to an order during a full-day run.
class TraceEvent {
  TraceEvent({
    required this.step,
    this.detail = '',
    this.micros = 0,
    this.failed = false,
    this.where,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final DateTime at;

  /// The cashier action, in English: 'ring', 'kitchen', 'hold', 'recall', ...
  final String step;
  final String detail;

  /// How long the till took over it.
  final int micros;
  final bool failed;

  /// Where the step sent the order: a table, the kitchen, a driver, another check.
  final String? where;

  Map<String, Object?> toJson() => {
    'at': at.toIso8601String(),
    'step': step,
    'detail': detail,
    'ms': (micros / 1000).toStringAsFixed(1),
    'failed': failed,
    'where': where,
  };
}

/// How an order the run touched should be found once the run is over.
class ExpectedOrder {
  ExpectedOrder.of(Order o)
    : uuid = o.uuid,
      gone = false,
      state = o.state,
      lineCount = o.lines.length,
      total = o.total,
      table = o.tableLabel,
      type = o.type,
      driverId = o.driverId,
      deliveryStatus = o.deliveryStatus,
      deviceId = o.deviceId;

  /// An order the cashier folded away or emptied: it must not be on the till.
  ExpectedOrder.gone(this.uuid)
    : gone = true,
      state = null,
      lineCount = 0,
      total = 0,
      table = null,
      type = null,
      driverId = null,
      deliveryStatus = null,
      deviceId = null;

  final String uuid;
  final bool gone;
  final OrderState? state;
  final int lineCount;
  final double total;
  final String? table;
  final OrderType? type;
  final String? driverId;
  final DeliveryStatus? deliveryStatus;
  final String? deviceId;
}

/// Everything one scenario did, from the first line rung to the last slip.
class OrderTrace {
  OrderTrace({
    required this.index,
    required this.scenario,
    required this.cashier,
    required this.device,
  }) : started = DateTime.now();

  final int index;
  final String scenario;
  final String cashier;
  final String device;
  final DateTime started;
  DateTime? finished;

  /// The main order: the one the scenario opened.
  String? uuid;
  String? orderNo;
  String? table;
  OrderType? type;

  /// Every order the scenario ended with, keyed by uuid (split checks, a moved
  /// tab, a merged-away source).
  final Map<String, ExpectedOrder> expected = {};

  /// What the bill came to before a split, so the checks can be added back up.
  double? splitFrom;
  final List<String> splitInto = [];

  /// When the course timer was due and when the kitchen actually got it.
  DateTime? timedDue;
  DateTime? timedFired;

  /// Kitchen fired for real (printing on) or simulated (printing off).
  bool kitchenSimulated = false;

  final List<TraceEvent> events = [];

  /// Filled by the integrity checks after the run.
  final List<StressNote> problems = [];

  /// A step that threw: the scenario stopped there.
  String? error;

  bool get hasProblems => error != null || problems.any((p) => p.alarm);

  Duration get duration => (finished ?? DateTime.now()).difference(started);

  void add(
    String step, {
    String detail = '',
    int micros = 0,
    bool failed = false,
    String? where,
  }) => events.add(
    TraceEvent(
      step: step,
      detail: detail,
      micros: micros,
      failed: failed,
      where: where,
    ),
  );

  /// Remember how [o] must look at the end (the latest call wins).
  void expect(Order o) => expected[o.uuid] = ExpectedOrder.of(o);

  void expectGone(String orderUuid) =>
      expected[orderUuid] = ExpectedOrder.gone(orderUuid);

  /// Note the main order the first time the scenario has one.
  void bind(Order o) {
    uuid ??= o.uuid;
    if (o.uuid == uuid) {
      orderNo = o.orderNo ?? orderNo;
      table = o.tableLabel ?? table;
      type = o.type;
    }
  }

  Map<String, Object?> toJson() => {
    'index': index,
    'scenario': scenario,
    'cashier': cashier,
    'device': device,
    'uuid': uuid,
    'order_no': orderNo,
    'table': table,
    'type': type?.name,
    'started': started.toIso8601String(),
    'ms': duration.inMilliseconds,
    'error': error,
    'split_into': splitInto,
    'problems': [
      for (final p in problems) {'text': p.fill(p.template), 'alarm': p.alarm},
    ],
    'events': [for (final e in events) e.toJson()],
  };
}
