import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'stress_lab_runner.dart';

/// Appends every finished Stress Lab run to a dated Markdown file beside the
/// till database, so a run can be read and compared after the screen is gone.
class StressReportLog {
  StressReportLog({Future<Directory> Function()? baseDir})
      : _baseDir = baseDir ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _baseDir;

  /// Where today's runs are written, once the first one has been.
  String? lastPath;

  Future<void> append(StressReport report) async {
    final now = DateTime.now();
    final day = now.toIso8601String().substring(0, 10);
    final dir = Directory('${(await _baseDir()).path}${Platform.pathSeparator}stress_reports');
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}stress-$day.md');
    await file.writeAsString(render(report, at: now), mode: FileMode.append, flush: true);
    lastPath = file.path;
  }

  /// One run as a Markdown section, in English (the templates' source language).
  static String render(StressReport r, {required DateTime at}) {
    final b = StringBuffer()
      ..writeln('## ${r.title} — ${at.toIso8601String().substring(11, 19)}')
      ..writeln()
      ..writeln('- Done: ${r.done} · failed: ${r.failed}');
    final lat = r.latency;
    if (lat != null && lat.count > 0) b.writeln('- Time per operation: $lat');
    for (final n in r.notes) {
      b.writeln('- ${n.alarm ? '**ALARM** ' : ''}${n.fill(n.template)}');
    }
    b.writeln();
    return b.toString();
  }
}
