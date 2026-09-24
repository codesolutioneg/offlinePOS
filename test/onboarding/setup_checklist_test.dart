import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/onboarding/setup_checklist.dart';

SetupChecklist listWith({
  bool server = false,
  bool menu = false,
  bool printer = false,
  bool staff = false,
  bool deviceRole = true,
}) =>
    SetupChecklist.of(
      serverConfigured: server,
      menuDownloaded: menu,
      printerConfigured: printer,
      staffEnrolled: staff,
      deviceRoleChosen: deviceRole,
    );

void main() {
  test('a till out of the box has everything still to do', () {
    final list = listWith(deviceRole: false);
    expect(list.isComplete, isFalse);
    expect(list.remaining, 5);
    expect(list.outstanding.map((s) => s.id),
        ['server', 'menu', 'printer', 'staff', 'lan_role']);
  });

  test('what is done drops off the outstanding list', () {
    final list = listWith(server: true, menu: true);
    expect(list.remaining, 2);
    expect(list.outstanding.map((s) => s.id), ['printer', 'staff']);
    // The done items are still on the list, ticked: the point is to show
    // progress, not to hide it.
    expect(list.steps.length, 5);
  });

  test('a finished install is complete', () {
    final list = listWith(server: true, menu: true, printer: true, staff: true);
    expect(list.isComplete, isTrue);
    expect(list.outstanding, isEmpty);
  });

  test('every step has a stable id, a title and a reason', () {
    final list = listWith(deviceRole: false);
    expect(list.steps.map((s) => s.id).toSet().length, list.steps.length);
    for (final s in list.steps) {
      expect(s.id, isNotEmpty);
      expect(s.title, isNotEmpty);
      expect(s.detail, isNotEmpty);
    }
  });
}
