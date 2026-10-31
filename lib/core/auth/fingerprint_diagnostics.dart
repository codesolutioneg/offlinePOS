import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'fingerprint_agent_launcher.dart';

/// One auto-setup / connect finding for tracking on a new till.
class FingerprintDiagCheck {
  const FingerprintDiagCheck({
    required this.code,
    required this.ok,
    required this.detail,
  });

  final String code;
  final bool ok;
  final String detail;

  factory FingerprintDiagCheck.fromMap(Map<String, dynamic> m) =>
      FingerprintDiagCheck(
        code: '${m['code'] ?? ''}',
        ok: m['ok'] == true,
        detail: '${m['detail'] ?? ''}',
      );
}

/// Result of [FingerprintDiagnostics.probe] — shown in enrol / settings.
class FingerprintDiagReport {
  const FingerprintDiagReport({
    required this.ok,
    required this.summary,
    this.logPath,
    this.statusFile,
    this.issues = const [],
    this.checks = const [],
  });

  final bool ok;
  final String summary;
  final String? logPath;
  final String? statusFile;
  final List<String> issues;
  final List<FingerprintDiagCheck> checks;

  String get trackingHint {
    final parts = <String>[
      if (logPath != null && logPath!.isNotEmpty) 'Log: $logPath',
      if (statusFile != null && statusFile!.isNotEmpty) 'Status: $statusFile',
    ];
    return parts.join('\n');
  }
}

/// Runs silent agent bootstrap and reads setup status + `/diag` for UI errors.
class FingerprintDiagnostics {
  FingerprintDiagnostics({
    this.baseUrl = 'http://127.0.0.1:9201',
    http.Client? client,
    FingerprintAgentLauncher? launcher,
  })  : _client = client ?? http.Client(),
        _launcher = launcher ?? FingerprintAgentLauncher();

  final String baseUrl;
  final http.Client _client;
  final FingerprintAgentLauncher _launcher;

  static String get _localStatusPath =>
      '${Platform.environment['LOCALAPPDATA'] ?? ''}'
      '\\OfflinePOS\\zk_setup_status.json';

  static String get _localLogPath =>
      '${Platform.environment['LOCALAPPDATA'] ?? ''}'
      '\\OfflinePOS\\zk_agent.log';

  /// Ensure agent is up (runs bat → setup_check → flask), then return a report.
  Future<FingerprintDiagReport> probe({bool forceSetup = false}) async {
    if (!Platform.isWindows) {
      return const FingerprintDiagReport(
        ok: false,
        summary: 'Fingerprint agent is Windows-only',
      );
    }

    await _launcher.ensureRunning(runSetup: true);
    // Give setup a moment if the bat is still installing pip packages.
    for (var i = 0; i < 40; i++) {
      if (await _launcher.isListening()) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    final fromFile = _readStatusFile();
    Map<String, dynamic>? fromAgent;
    try {
      final res = await _client
          .get(Uri.parse('$baseUrl/diag'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final body = jsonDecode(res.body);
        if (body is Map) fromAgent = body.cast<String, dynamic>();
      }
    } catch (_) {}

    if (fromAgent != null) {
      final checks = <FingerprintDiagCheck>[
        for (final c in (fromAgent['setup'] is Map
                ? (fromAgent['setup'] as Map)['checks']
                : null) as List? ??
            const [])
          if (c is Map)
            FingerprintDiagCheck.fromMap(c.cast<String, dynamic>()),
      ];
      final issues = [
        for (final i in fromAgent['issues'] as List? ?? const []) '$i',
      ];
      final ok = fromAgent['ok'] == true || fromAgent['device_ok'] == true;
      return FingerprintDiagReport(
        ok: ok,
        summary: '${fromAgent['summary'] ?? (ok ? 'OK' : 'Not ready')}',
        logPath: '${fromAgent['log_path'] ?? _localLogPath}',
        statusFile: fromAgent['setup'] is Map
            ? '${(fromAgent['setup'] as Map)['status_file'] ?? _localStatusPath}'
            : _localStatusPath,
        issues: issues,
        checks: checks,
      );
    }

    if (fromFile != null) {
      final checks = <FingerprintDiagCheck>[
        for (final c in fromFile['checks'] as List? ?? const [])
          if (c is Map)
            FingerprintDiagCheck.fromMap(c.cast<String, dynamic>()),
      ];
      final ok = fromFile['ok'] == true && fromFile['can_start_agent'] == true;
      final summary = '${fromFile['summary'] ?? 'Setup incomplete'}';
      return FingerprintDiagReport(
        ok: ok && await _launcher.isListening(),
        summary: summary,
        logPath: '${fromFile['log_path'] ?? _localLogPath}',
        statusFile: _localStatusPath,
        issues: [
          for (final c in checks)
            if (!c.ok) '${c.code}: ${c.detail}',
        ],
        checks: checks,
      );
    }

    final listening = await _launcher.isListening();
    return FingerprintDiagReport(
      ok: listening,
      summary: listening
          ? 'Agent up but no setup status yet'
          : 'Agent did not start — check Python / tools folder. '
              'Log: $_localLogPath',
      logPath: _localLogPath,
      statusFile: _localStatusPath,
      issues: listening
          ? const []
          : [
              'Agent not listening on 127.0.0.1:9201',
              'Run tools\\start_zk_agent.bat and read the window / log',
            ],
    );
  }

  Map<String, dynamic>? _readStatusFile() {
    for (final path in [
      _localStatusPath,
      ..._toolsStatusCandidates(),
    ]) {
      try {
        final f = File(path);
        if (!f.existsSync()) continue;
        final body = jsonDecode(f.readAsStringSync());
        if (body is Map) return body.cast<String, dynamic>();
      } catch (_) {}
    }
    return null;
  }

  List<String> _toolsStatusCandidates() {
    final bat = _launcher.resolveBatPath();
    if (bat == null) return const [];
    return ['${File(bat).parent.path}\\zk_setup_status.json'];
  }
}
