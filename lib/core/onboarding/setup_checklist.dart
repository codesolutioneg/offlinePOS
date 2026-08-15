/// One thing a freshly installed till still has to be told.
///
/// [id] is the widget key and never a label, so the wording can change without
/// breaking a test or a translation lookup.
class SetupStep {
  const SetupStep({
    required this.id,
    required this.title,
    required this.detail,
    required this.done,
  });

  final String id;
  final String title;
  final String detail;
  final bool done;
}

/// What is still unset on this till, in the order somebody setting one up does it.
///
/// A till that has never been pointed at a server, has no menu, no printer and no
/// staff still sells: everything is local and the cashier can ring a sale on it as
/// it comes out of the box. That is exactly why this is needed. Nothing complains,
/// so an install that stopped halfway looks identical to a finished one until the
/// first shift close finds nowhere to send the day.
///
/// Deliberately built from facts already on the device (is there an endpoint, has
/// the catalogue ever been pulled, is a printer registered, is there a roster), so
/// it is the same answer with the network down.
class SetupChecklist {
  const SetupChecklist(this.steps);

  factory SetupChecklist.of({
    required bool serverConfigured,
    required bool menuDownloaded,
    required bool printerConfigured,
    required bool staffEnrolled,
  }) =>
      SetupChecklist([
        SetupStep(
          id: 'server',
          title: 'Point the till at your server',
          detail: 'Where the day is sent when a shift closes.',
          done: serverConfigured,
        ),
        SetupStep(
          id: 'menu',
          title: 'Download the menu',
          detail: 'Products, prices and payment methods come from the server.',
          done: menuDownloaded,
        ),
        SetupStep(
          id: 'printer',
          title: 'Add a printer',
          detail: 'Receipts and kitchen tickets need somewhere to go.',
          done: printerConfigured,
        ),
        SetupStep(
          id: 'staff',
          title: 'Add your staff',
          detail: 'Everyone who rings a sale needs their own PIN.',
          done: staffEnrolled,
        ),
      ]);

  final List<SetupStep> steps;

  bool get isComplete => steps.every((s) => s.done);

  List<SetupStep> get outstanding =>
      steps.where((s) => !s.done).toList(growable: false);

  int get remaining => outstanding.length;
}
