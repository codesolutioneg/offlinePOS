/// Latency figures for a batch of timed operations, recorded in microseconds.
class LatencyStats {
  LatencyStats(List<int> micros) : _sorted = [...micros]..sort();

  final List<int> _sorted;

  int get count => _sorted.length;

  double _ms(int us) => us / 1000;

  double get avgMs =>
      _sorted.isEmpty ? 0 : _ms(_sorted.reduce((a, b) => a + b)) / _sorted.length;

  double get maxMs => _sorted.isEmpty ? 0 : _ms(_sorted.last);

  double percentileMs(double p) =>
      _sorted.isEmpty ? 0 : _ms(_sorted[((_sorted.length - 1) * p).round()]);

  @override
  String toString() => 'avg ${avgMs.toStringAsFixed(1)} ms · '
      'p95 ${percentileMs(0.95).toStringAsFixed(1)} ms · '
      'max ${maxMs.toStringAsFixed(1)} ms';
}
