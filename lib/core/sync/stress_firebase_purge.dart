import 'dart:convert';
import 'dart:io';

import '../db/database.dart';
import '../db/stress_purge.dart';
import 'dishflow_mirror.dart';

/// One Firestore document a Stress Lab order reached before the guard existed
/// (or on a till that ran an older build).
class StressFirebaseDoc {
  const StressFirebaseDoc({
    required this.projectId,
    required this.apiKey,
    required this.path,
  });

  final String projectId;
  final String apiKey;

  /// `sales/{id}` or `drivers/{id}/orders/{sale}`.
  final String path;

  Uri get url => Uri.parse(
    'https://firestore.googleapis.com/v1/projects/$projectId'
    '/databases/(default)/documents/$path?key=$apiKey',
  );
}

/// What a full cleanup did, so the screen can say where the lab's data went.
class StressCleanup {
  const StressCleanup({
    this.removed = 0,
    this.firebaseDeleted = 0,
    this.firebaseFailed = 0,
    this.inOdoo = const [],
  });

  final int removed;
  final int firebaseDeleted;
  final int firebaseFailed;

  /// Lab orders Odoo already booked. Nothing on the till can take them back, so
  /// they are named for a manager to cancel by hand.
  final List<String> inOdoo;
}

/// Answers a DELETE with its HTTP status. Injected by tests.
typedef FirestoreDelete = Future<int> Function(Uri url);

/// Every mirror copy of a lab order that already reached Dishflow, read from the
/// queue rows marked sent (kept a week before they are pruned).
List<StressFirebaseDoc> sentStressDocs(Db db) {
  final uuids = stressOrderUuids(db).toSet();
  if (uuids.isEmpty) return const [];
  final rows = db.raw.select(
    'SELECT payload_uuid, payload FROM outbox WHERE sent_at IS NOT NULL AND kind IN (?, ?)',
    [DishflowMirror.kind, DishflowMirror.driverOrderKind],
  );
  final docs = <StressFirebaseDoc>[];
  for (final r in rows) {
    final key = r['payload_uuid'] as String;
    if (!uuids.contains(key.split('|').first)) continue;
    final p = jsonDecode(r['payload'] as String) as Map<String, dynamic>;
    final docPath = (p['doc_path'] ?? '').toString().trim();
    final docId = (p['doc_id'] ?? '').toString().trim();
    final path = docPath.isNotEmpty
        ? docPath
        : (docId.isEmpty ? '' : 'sales/$docId');
    final project = (p['project_id'] ?? '').toString().trim();
    final apiKey = (p['api_key'] ?? '').toString().trim();
    if (path.isEmpty || project.isEmpty || apiKey.isEmpty) continue;
    docs.add(StressFirebaseDoc(projectId: project, apiKey: apiKey, path: path));
  }
  return docs;
}

/// Lab orders that reached Odoo: their push was acknowledged, or they were marked
/// synced by a till (the history the lab seeds itself is synced by design and
/// never went anywhere, so it is left out).
List<String> stressOrdersInOdoo(Db db) {
  final sent = db.raw
      .select(
        "SELECT payload_uuid FROM outbox WHERE kind = 'order.push' "
        'AND sent_at IS NOT NULL',
      )
      .map((r) => r['payload_uuid'] as String)
      .toSet();
  final rows = db.raw.select(
    "SELECT uuid, json_extract(payload, '\$.order_no') no, "
    "json_extract(payload, '\$.state') st, json_extract(payload, '\$.device_id') dev "
    'FROM orders WHERE payload LIKE ?',
    [kStressNoteMatch],
  );
  return [
    for (final r in rows)
      if (sent.contains(r['uuid']) ||
          (r['st'] == 'synced' && r['dev'] != kStressHistoryDevice))
        '#${r['no'] ?? (r['uuid'] as String).substring(0, 8)}',
  ];
}

/// The device id the lab's seeded history is written under.
const String kStressHistoryDevice = 'stress-history';

/// Removes lab orders from everywhere they can be: Dishflow's Firestore, then the
/// till's own tables and queue.
class StressFirebasePurge {
  StressFirebasePurge({FirestoreDelete? delete})
    : _delete = delete ?? _httpDelete;

  final FirestoreDelete _delete;

  /// Read what reached Dishflow and Odoo, purge the till, then delete the
  /// Firestore copies. The local purge runs before the first await, so the lab's
  /// rows are gone even if the network never answers.
  Future<StressCleanup> purgeEverywhere(Db db) async {
    final docs = sentStressDocs(db);
    final inOdoo = stressOrdersInOdoo(db);
    final removed = purgeStressOrders(db);
    var deleted = 0;
    var failed = 0;
    for (final d in docs) {
      try {
        final status = await _delete(d.url);
        // Gone already reads the same as deleted now.
        if (status == 200 || status == 204 || status == 404) {
          deleted++;
        } else {
          failed++;
        }
      } catch (_) {
        failed++;
      }
    }
    return StressCleanup(
      removed: removed,
      firebaseDeleted: deleted,
      firebaseFailed: failed,
      inOdoo: inOdoo,
    );
  }

  static Future<int> _httpDelete(Uri url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.deleteUrl(url);
      final res = await req.close().timeout(const Duration(seconds: 20));
      await res.drain<void>();
      return res.statusCode;
    } finally {
      client.close(force: true);
    }
  }
}
