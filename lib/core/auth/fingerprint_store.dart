import 'dart:async';
import 'dart:convert';

import '../db/database.dart';
import '../lan/lan_event.dart';
import 'fingerprint_service.dart';

/// One enrolled finger for a staff member (ZK template bytes as JSON list).
class FingerprintTemplate {
  const FingerprintTemplate({
    required this.userId,
    required this.slot,
    required this.template,
  });

  final String userId;
  final int slot;
  final List<int> template;

  Map<String, dynamic> toMap() => {
        'user_id': userId,
        'slot': slot,
        'template': template,
      };

  factory FingerprintTemplate.fromMap(Map<String, dynamic> m) =>
      FingerprintTemplate(
        userId: '${m['user_id']}',
        slot: (m['slot'] as num?)?.toInt() ?? 0,
        template: List<int>.from(m['template'] as List? ?? const []),
      );
}

/// Local fingerprint bank + optional LAN publish so every till can identify.
class FingerprintStore {
  FingerprintStore(
    this._db, {
    LanPublish? publish,
    FingerprintService? service,
  })  : _publish = publish,
        _service = service;

  final Db _db;
  final LanPublish? _publish;
  final FingerprintService? _service;

  static String recordKey(String userId) => 'fingerprint:$userId';

  List<FingerprintTemplate> forUser(String userId) {
    final rows = _db.raw.select(
      'SELECT user_id, slot, template FROM fingerprint_templates '
      'WHERE user_id = ? ORDER BY slot',
      [userId],
    );
    return [
      for (final r in rows)
        FingerprintTemplate(
          userId: r['user_id'] as String,
          slot: r['slot'] as int,
          template: List<int>.from(jsonDecode(r['template'] as String) as List),
        ),
    ];
  }

  bool hasAny(String userId) => forUser(userId).isNotEmpty;

  List<String> enrolledUserIds() => _db.raw
      .select('SELECT DISTINCT user_id FROM fingerprint_templates')
      .map((r) => r['user_id'] as String)
      .toList();

  /// Replace all slots for [userId] with [templates] (usually one merged print).
  void saveUserTemplates(
    String userId,
    List<List<int>> templates, {
    bool announce = true,
  }) {
    _db.raw.execute(
        'DELETE FROM fingerprint_templates WHERE user_id = ?', [userId]);
    var slot = 0;
    for (final t in templates) {
      if (t.isEmpty) continue;
      _db.raw.execute(
        'INSERT INTO fingerprint_templates (user_id, slot, template) '
        'VALUES (?,?,?)',
        [userId, slot++, jsonEncode(t)],
      );
    }
    if (announce) {
      _publish?.call(
        LanEventKind.fingerprintUpsert,
        recordKey(userId),
        {
          'user_id': userId,
          'templates': templates,
          if (templates.isEmpty) 'deleted': true,
        },
      );
    }
    unawaited(_pushAgent());
  }

  void clearUser(String userId, {bool announce = true}) =>
      saveUserTemplates(userId, const [], announce: announce);

  /// Wipe every local template, then load the primary's join bank (no LAN echo).
  /// Does not push to the USB agent — caller should [pushToAgent] once afterward.
  void replaceAllForJoin(List<Map<String, dynamic>> entries) {
    _db.raw.execute('DELETE FROM fingerprint_templates');
    for (final m in entries) {
      final uid = '${m['user_id'] ?? ''}';
      if (uid.isEmpty) continue;
      final raw = m['templates'] as List? ?? const [];
      var slot = 0;
      for (final t in raw) {
        final list = List<int>.from(t as List);
        if (list.isEmpty) continue;
        _db.raw.execute(
          'INSERT INTO fingerprint_templates (user_id, slot, template) '
          'VALUES (?,?,?)',
          [uid, slot++, jsonEncode(list)],
        );
      }
    }
  }

  /// Apply a peer's enrol / clear without echoing back onto the fabric.
  void applyRemote(Map<String, dynamic> payload) {
    final userId = '${payload['user_id'] ?? ''}';
    if (userId.isEmpty) return;
    if (payload['deleted'] == true) {
      saveUserTemplates(userId, const [], announce: false);
      return;
    }
    final raw = payload['templates'] as List? ?? const [];
    final templates = <List<int>>[
      for (final t in raw) List<int>.from(t as List),
    ];
    saveUserTemplates(userId, templates, announce: false);
  }

  /// Shape the agent expects for /load_templates.
  List<Map<String, dynamic>> agentPayload() {
    final byUser = <String, List<List<int>>>{};
    for (final r in _db.raw.select(
        'SELECT user_id, slot, template FROM fingerprint_templates '
        'ORDER BY user_id, slot')) {
      final id = r['user_id'] as String;
      byUser
          .putIfAbsent(id, () => [])
          .add(List<int>.from(jsonDecode(r['template'] as String) as List));
    }
    return [
      for (final e in byUser.entries)
        {'user_id': e.key, 'templates': e.value},
    ];
  }

  Future<void> pushToAgent() => _pushAgent();

  Future<void> _pushAgent() async {
    final svc = _service;
    if (svc == null) return;
    try {
      if (!await svc.warmUp()) return;
      await svc.loadTemplates(agentPayload());
    } catch (_) {}
  }
}
