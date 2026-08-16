/// The block that goes at the top of every exported report, whatever the format.
///
/// A report that leaves the till as a bare grid of numbers is worthless a week
/// later: nobody can say which shop it came from, which period it covers or who
/// ran it. The same block is rendered by the CSV, the PDF and the workbook, so a
/// manager who prints one and mails another is holding the same document.
///
/// The lines are already translated by the caller, because this lives below the
/// widget tree and has no locale of its own.
class ExportHeader {
  const ExportHeader({required this.title, this.lines = const []});

  /// The report's own name, e.g. "Expenses".
  final String title;

  /// Label/value pairs under the title: the shop, the period, who ran it, when.
  final List<(String, String)> lines;
}

/// `<yyyy-mm-dd hh:mm>` in local time, the stamp every export header carries.
String exportStamp(DateTime at) {
  final l = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}
