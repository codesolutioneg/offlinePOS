import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/onboarding/setup_checklist.dart';

SetupChecklist listWith({
  bool server = false,
  bool menu = false,
  bool printer = false,
  bool staff = false,
}) =>
    SetupChecklist.of(
      serverConfigured: server,
      menuDownloaded: menu,
      printerConfigured: printer,
      staffEnrolled: staff,
    );

void main() {
  test('a till out of the box has everything still to do', () {
    final list = listWith();
    expect(list.isComplete, isFalse);
    expect(list.remaining, 4);
    expect(list.outstanding.map((s) => s.id),
        ['server', 'menu', 'printer', 'staff']);
  });

  test('what is done drops off the outstanding list', () {
    final list = listWith(server: true, menu: true);
    expect(list.remaining, 2);
    expect(list.outstanding.map((s) => s.id), ['printer', 'staff']);
    // The done items are still on the list, ticked: the point is to show
    // progress, not to hide it.
    expect(list.steps.length, 4);
  });

  test('a finished install is complete', () {
    final list = listWith(server: true, menu: true, printer: true, staff: true);
    expect(list.isComplete, isTrue);
    expect(list.outstanding, isEmpty);
  });

  test('every step has a stable id, a title and a reason', () {
    final list = listWith();
    expect(list.steps.map((s) => s.id).toSet().length, list.steps.length);
    for (final s in list.steps) {
      expect(s.id, isNotEmpty);
      expect(s.title, isNotEmpty);
      expect(s.detail, isNotEmpty);
    }
  });
}
