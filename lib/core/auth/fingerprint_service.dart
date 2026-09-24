import 'dart:convert';

import 'package:http/http.dart' as http;

/// Talks to [tools/zk_fingerprint_agent.py] on 127.0.0.1:9201 (ZKTeco USB).
///
/// When the agent or the reader is missing, every call fails soft so the till
/// falls back to PIN — biometrics never block a sale.
class FingerprintService {
  FingerprintService({
    this.baseUrl = 'http://127.0.0.1:9201',
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  bool _available = false;
  DateTime? _lastWarm;
  Future<bool>? _warmInFlight;

  /// Last connect / warm failure (for UI tracking). Cleared on success.
  String? lastError;

  /// Last known readiness (agent up + device connected). Instant, no I/O.
  bool get availableCached => _available;

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  Future<Map<String, dynamic>?> _json(
    Future<http.Response> Function() call,
  ) async {
    try {
      final res = await call();
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final body = jsonDecode(res.body);
      if (body is Map<String, dynamic>) return body;
      if (body is Map) return body.cast<String, dynamic>();
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> isAgentRunning() async {
    final data = await _json(() => _client
        .get(_u('/ping'))
        .timeout(const Duration(seconds: 3)));
    return data != null && data['status'] == 'ok';
  }

  Future<bool> connect() async {
    final data = await _json(() => _client
        .post(_u('/connect'))
        .timeout(const Duration(seconds: 8)));
    final ok = data?['success'] == true;
    if (!ok) {
      lastError = '${data?['message'] ?? 'Fingerprint connect failed'}';
    } else {
      lastError = null;
    }
    return ok;
  }

  Future<void> disconnect() async {
    try {
      await _client
          .post(_u('/disconnect'))
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// Confirm the reader is ready and cache the result for [ttl].
  Future<bool> warmUp({
    bool force = false,
    Duration ttl = const Duration(seconds: 45),
  }) {
    if (!force &&
        _lastWarm != null &&
        DateTime.now().difference(_lastWarm!) < ttl) {
      return Future.value(_available);
    }
    return _warmInFlight ??= _doWarm();
  }

  Future<bool> _doWarm() async {
    try {
      final ok = await connect();
      _available = ok;
      _lastWarm = DateTime.now();
      return ok;
    } finally {
      _warmInFlight = null;
    }
  }

  Future<bool> get isConnected async {
    final data = await _json(() => _client
        .get(_u('/status'))
        .timeout(const Duration(seconds: 3)));
    return data?['connected'] == true;
  }

  /// Wait for a finger; returns raw template bytes, or null.
  Future<List<int>?> captureTemplate({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final data = await _json(() => _client
        .post(
          _u('/capture'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'timeout': timeout.inSeconds}),
        )
        .timeout(timeout + const Duration(seconds: 3)));
    if (data?['success'] != true) return null;
    final tmpl = List<int>.from(data!['template'] as List);
    if (tmpl.every((b) => b == 0)) return null;
    return tmpl;
  }

  /// Merge three captures into one registration template (ZK DBMerge).
  Future<List<int>?> mergeTemplates(List<List<int>> captures) async {
    final data = await _json(() => _client
        .post(
          _u('/merge'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'templates': captures}),
        )
        .timeout(const Duration(seconds: 15)));
    if (data?['success'] != true) return null;
    final merged = List<int>.from(data!['template'] as List);
    if (merged.every((b) => b == 0)) return null;
    return merged;
  }

  Future<bool> registerUser({
    required String userId,
    required List<int> template,
  }) async {
    final data = await _json(() => _client
        .post(
          _u('/register'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'user_id': userId, 'template': template}),
        )
        .timeout(const Duration(seconds: 8)));
    return data?['success'] == true;
  }

  /// One listen cycle: wait for a finger, then match the local template bank.
  Future<FingerprintIdentifyOutcome> identifyOnce({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final data = await _json(() => _client
        .post(
          _u('/identify'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'timeout': timeout.inSeconds}),
        )
        .timeout(timeout + const Duration(seconds: 4)));
    if (data == null) return const FingerprintIdentifyUnavailable();
    if (data['success'] == true) {
      final uid = data['user_id']?.toString();
      if (uid != null && uid.isNotEmpty) {
        return FingerprintIdentifyMatch(uid);
      }
    }
    final reason = '${data['reason'] ?? ''}';
    return switch (reason) {
      'timeout' => const FingerprintIdentifyTimeout(),
      'empty_bank' => const FingerprintIdentifyEmptyBank(),
      'no_match' => FingerprintIdentifyNoMatch(
          score: (data['score'] as num?)?.toInt() ?? 0,
        ),
      'not_connected' || 'error' || 'invalid' =>
        const FingerprintIdentifyUnavailable(),
      _ => const FingerprintIdentifyTimeout(),
    };
  }

  /// Identify against templates already loaded into the agent.
  Future<String?> identifyUser({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final outcome = await identifyOnce(timeout: timeout);
    return switch (outcome) {
      FingerprintIdentifyMatch(:final userId) => userId,
      _ => null,
    };
  }

  Future<bool> clearPending() async {
    final data = await _json(() => _client
        .post(_u('/clear_pending'))
        .timeout(const Duration(seconds: 3)));
    return data?['success'] == true;
  }

  /// Push the till's template bank into the agent so identify works offline.
  ///
  /// Shape: `[{user_id, templates: [[int,...], ...]}, ...]`
  Future<bool> loadTemplates(List<Map<String, dynamic>> templates) async {
    final data = await _json(() => _client
        .post(
          _u('/load_templates'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'templates': templates}),
        )
        .timeout(const Duration(seconds: 10)));
    return data?['success'] == true;
  }

  Future<bool> deleteTemplate(String userId) async {
    final data = await _json(() => _client
        .delete(_u('/template/$userId'))
        .timeout(const Duration(seconds: 5)));
    return data?['success'] == true;
  }

  void dispose() => _client.close();
}

/// Result of one [FingerprintService.identifyOnce] listen cycle.
sealed class FingerprintIdentifyOutcome {
  const FingerprintIdentifyOutcome();
}

class FingerprintIdentifyMatch extends FingerprintIdentifyOutcome {
  const FingerprintIdentifyMatch(this.userId);
  final String userId;
}

class FingerprintIdentifyNoMatch extends FingerprintIdentifyOutcome {
  const FingerprintIdentifyNoMatch({this.score = 0});
  final int score;
}

class FingerprintIdentifyTimeout extends FingerprintIdentifyOutcome {
  const FingerprintIdentifyTimeout();
}

class FingerprintIdentifyEmptyBank extends FingerprintIdentifyOutcome {
  const FingerprintIdentifyEmptyBank();
}

class FingerprintIdentifyUnavailable extends FingerprintIdentifyOutcome {
  const FingerprintIdentifyUnavailable();
}
