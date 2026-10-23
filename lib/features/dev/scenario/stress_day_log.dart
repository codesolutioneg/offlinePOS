import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'stress_day_runner.dart';
import 'stress_trace.dart';

/// Writes a full-day run to `stress_reports/` beside the till database: a
/// Markdown summary, every order as JSON, and one CSV row per order. The device
/// id is in every file name, so the two tills' reports can be laid side by side.
class StressDayLog {
  StressDayLog({Future<Directory> Function()? baseDir})
    : _baseDir = baseDir ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _baseDir;

  /// The Markdown file of the last run written.
  String? lastPath;

  Future<void> write(StressDayReport r) async {
    final sep = Platform.pathSeparator;
    final dir = Directory('${(await _baseDir()).path}${sep}stress_reports');
    await dir.create(recursive: true);
    final stamp = r.started
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(':', '-');
    final device = r.device.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final base = '${dir.path}${sep}stress-day-$device-$stamp';
    await File('$base.md').writeAsString(markdown(r), flush: true);
    await File('$base.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(json(r)),
      flush: true,
    );
    await File('$base.csv').writeAsString(csv(r), flush: true);
    lastPath = '$base.md';
  }

  /// The run in English (the templates' source language).
  static String markdown(StressDayReport r) {
    final b = StringBuffer()
      ..writeln('# Full-day stress — ${r.config.mode.name} — ${r.device}')
      ..writeln()
      ..writeln(
        '- Started ${r.started.toIso8601String()} · '
        '${r.config.orders} orders · ${r.config.cashiers} cashiers · '
        'printing ${r.config.printing ? 'on' : 'off'}',
      )
      ..writeln('- Time per till step: ${r.latency}');
    for (final n in r.notes) {
      b.writeln('- ${n.alarm ? '**ALARM** ' : ''}${n.fill(n.template)}');
    }
    final bad = r.traces.where((t) => t.hasProblems).toList();
    b
      ..writeln()
      ..writeln('## Orders with problems (${bad.length})');
    for (final t in bad) {
      b
        ..writeln()
        ..writeln('### ${_title(t)}');
      for (final p in t.problems.where((p) => p.alarm)) {
        b.writeln('- ${p.fill(p.template)}');
      }
      if (t.error != null) b.writeln('- stopped: ${t.error}');
      for (final e in t.events) {
        b.writeln(
          '  - ${e.at.toIso8601String().substring(11, 23)} ${e.step}'
          '${e.where == null ? '' : ' → ${e.where}'}'
          '${e.detail.isEmpty ? '' : ' (${e.detail})'}'
          ' · ${(e.micros / 1000).toStringAsFixed(1)} ms${e.failed ? ' · FAILED' : ''}',
        );
      }
    }
    return b.toString();
  }

  static String _title(OrderTrace t) =>
      '${t.index}. ${t.scenario} · #${t.orderNo ?? '-'}'
      ' · ${t.table ?? t.type?.name ?? ''} · ${t.cashier} · ${t.duration.inMilliseconds} ms';

  /// Every order, with how it was left, so two tills' files can be compared on
  /// the same uuid.
  static Map<String, Object?> json(StressDayReport r) => {
    'device': r.device,
    'mode': r.config.mode.name,
    'started': r.started.toIso8601String(),
    'finished': r.finished.toIso8601String(),
    'notes': [
      for (final n in r.notes) {'text': n.fill(n.template), 'alarm': n.alarm},
    ],
    'orders': [
      for (final t in r.traces)
        {
          ...t.toJson(),
          'left_as': [
            for (final w in t.expected.values)
              {
                'uuid': w.uuid,
                'gone': w.gone,
                'state': w.state?.name,
                'lines': w.lineCount,
                'total': w.total.toStringAsFixed(2),
                'table': w.table,
              },
          ],
        },
    ],
  };

  static String csv(StressDayReport r) {
    String cell(Object? v) => '"${'${v ?? ''}'.replaceAll('"', '""')}"';
    final b = StringBuffer()
      ..writeln(
        'index,scenario,cashier,device,order_no,uuid,table,type,ms,steps,'
        'stopped,problems',
      );
    for (final t in r.traces) {
      b.writeln(
        [
          t.index,
          t.scenario,
          t.cashier,
          t.device,
          t.orderNo,
          t.uuid,
          t.table,
          t.type?.name,
          t.duration.inMilliseconds,
          t.events.length,
          t.error,
          t.problems
              .where((p) => p.alarm)
              .map((p) => p.fill(p.template))
              .join(' | '),
        ].map(cell).join(','),
      );
    }
    return b.toString();
  }
}
