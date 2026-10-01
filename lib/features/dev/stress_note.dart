/// One line of a Stress Lab report, kept as an English template plus values so
/// the screen can translate it: `'{n} orders in {s} s'` with `{'n': 100, 's': '1.2'}`.
class StressNote {
  const StressNote(this.template, [this.args = const {}, this.alarm = false]);

  final String template;
  final Map<String, Object> args;

  /// Something a manager has to look at: a repeated number, a lost sale, a failure.
  final bool alarm;

  /// Fill [translated] (the template in the screen's language) with the values.
  String fill(String translated) {
    var out = translated;
    args.forEach((k, v) => out = out.replaceAll('{$k}', '$v'));
    return out;
  }
}
