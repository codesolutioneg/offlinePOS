import 'dart:convert';
import 'dart:io';

import 'outbox.dart';

/// Writes one `sales/{docId}` document over the Firestore REST API.
///
/// Desktop tills stay free of `cloud_firestore`: one HTTPS PATCH, same shape
/// Dishflow's reports already decode. Failures throw so the outbox retries;
/// a permanent 4xx (except 409) parks the row.
class DishflowFirestoreSender {
  DishflowFirestoreSender({HttpClient Function()? openClient})
      : _openClient = openClient ?? HttpClient.new;

  final HttpClient Function() _openClient;

  /// Outbox handler for [DishflowMirror.kind].
  Future<void> call(OutboxEntry entry) => send(entry.payload);

  Future<void> send(Map<String, dynamic> payload) async {
    final projectId = (payload['project_id'] ?? '').toString().trim();
    final apiKey = (payload['api_key'] ?? '').toString().trim();
    final docId = (payload['doc_id'] ?? '').toString().trim();
    final fields = payload['fields'];
    if (projectId.isEmpty || apiKey.isEmpty || docId.isEmpty) {
      throw PermanentlyRejected('dishflow mirror missing project, key or doc id');
    }
    if (fields is! Map) {
      throw PermanentlyRejected('dishflow mirror payload has no fields');
    }

    final encoded = <String, dynamic>{
      for (final e in fields.entries)
        e.key.toString(): encodeValue(e.value),
    };
    // Server timestamp for when the mirror landed, distinct from orderCreatedAt.
    encoded['timestamp'] = {
      'timestampValue': DateTime.now().toUtc().toIso8601String(),
    };

    final url = Uri.parse(
      'https://firestore.googleapis.com/v1/projects/$projectId'
      '/databases/(default)/documents/sales/$docId?key=$apiKey',
    );

    final client = _openClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.patchUrl(url);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.add(utf8.encode(jsonEncode({'fields': encoded})));
      final res = await req.close().timeout(const Duration(seconds: 30));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 200 || res.statusCode == 201) return;
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw PermanentlyRejected(
            'dishflow firestore refused the write (${res.statusCode}): $body');
      }
      if (res.statusCode == 400) {
        throw PermanentlyRejected(
            'dishflow firestore rejected the document: $body');
      }
      throw StateError(
          'dishflow firestore HTTP ${res.statusCode}: $body');
    } finally {
      client.close(force: true);
    }
  }

  /// Firestore REST value encoding. Exposed for tests.
  static Map<String, dynamic> encodeValue(Object? value) {
    if (value == null) return {'nullValue': null};
    if (value is bool) return {'booleanValue': value};
    if (value is int) return {'integerValue': '$value'};
    if (value is double) {
      if (value.isNaN || value.isInfinite) {
        return {'doubleValue': 0};
      }
      return {'doubleValue': value};
    }
    if (value is num) return {'doubleValue': value.toDouble()};
    if (value is String) return {'stringValue': value};
    if (value is DateTime) {
      return {'timestampValue': value.toUtc().toIso8601String()};
    }
    if (value is List) {
      return {
        'arrayValue': {
          'values': [for (final v in value) encodeValue(v)],
        },
      };
    }
    if (value is Map) {
      return {
        'mapValue': {
          'fields': {
            for (final e in value.entries)
              e.key.toString(): encodeValue(e.value),
          },
        },
      };
    }
    return {'stringValue': value.toString()};
  }

  /// Writes `diagnostics/offlinepos_ping` rather than a sale.
  Future<String> testConnection({
    required String projectId,
    required String apiKey,
  }) async {
    final url = Uri.parse(
      'https://firestore.googleapis.com/v1/projects/$projectId'
      '/databases/(default)/documents/diagnostics/offlinepos_ping?key=$apiKey',
    );
    final client = _openClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.patchUrl(url);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      final fields = {
        'ok': encodeValue(true),
        'at': encodeValue(DateTime.now().toUtc().toIso8601String()),
        'source': encodeValue('offline_pos'),
      };
      req.add(utf8.encode(jsonEncode({'fields': fields})));
      final res = await req.close().timeout(const Duration(seconds: 20));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 200 || res.statusCode == 201) {
        return 'ok';
      }
      return 'HTTP ${res.statusCode}: $body';
    } on Object catch (e) {
      return 'failed: $e';
    } finally {
      client.close(force: true);
    }
  }
}
