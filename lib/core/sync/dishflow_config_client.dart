import 'dart:convert';
import 'dart:io';

import 'ecommerce_orders_client.dart';

/// One Firestore document: its id and its decoded fields.
typedef DishflowDoc = ({String id, Map<String, dynamic> fields});

/// Reads Dishflow branch configuration over the Firestore REST API.
///
/// Read-only by construction: every call here is a GET. Same credentials as the
/// owner mirror ([SettingsStore] project id + API key), and like it, no
/// `cloud_firestore` dependency.
class DishflowConfigClient {
  DishflowConfigClient({HttpClient Function()? openClient})
      : _openClient = openClient ?? HttpClient.new;

  final HttpClient Function() _openClient;

  /// Every document in [collection], following page tokens to the end.
  ///
  /// [fields] narrows what the server sends back to those fields alone, for a
  /// collection that also holds things this till has no business receiving.
  Future<List<DishflowDoc>> listCollection({
    required String projectId,
    required String apiKey,
    required String collection,
    List<String> fields = const [],
  }) async {
    final out = <DishflowDoc>[];
    String? pageToken;
    // A floor is tens of documents; the cap only stops a server that keeps
    // handing back the same token from spinning the till forever.
    for (var page = 0; page < 50; page++) {
      final url = Uri.https(
        'firestore.googleapis.com',
        '/v1/projects/$projectId/databases/(default)/documents/$collection',
        {
          'key': apiKey,
          'pageSize': '300',
          'pageToken': ?pageToken,
          if (fields.isNotEmpty) 'mask.fieldPaths': fields,
        },
      );
      final decoded = await _getJson(url, what: collection);
      if (decoded == null) break;
      final docs = decoded['documents'];
      if (docs is List) {
        for (final doc in docs) {
          if (doc is! Map) continue;
          final id = '${doc['name'] ?? ''}'.split('/').last;
          if (id.isEmpty) continue;
          out.add((
            id: id,
            fields: EcommerceOrdersClient.decodeFields(doc['fields']),
          ));
        }
      }
      final next = decoded['nextPageToken'];
      if (next is! String || next.isEmpty) break;
      pageToken = next;
    }
    return out;
  }

  /// One document's fields, or null when it does not exist.
  Future<Map<String, dynamic>?> getDocument({
    required String projectId,
    required String apiKey,
    required String path,
  }) async {
    final url = Uri.https(
      'firestore.googleapis.com',
      '/v1/projects/$projectId/databases/(default)/documents/$path',
      {'key': apiKey},
    );
    final decoded = await _getJson(url, what: path);
    if (decoded == null) return null;
    return EcommerceOrdersClient.decodeFields(decoded['fields']);
  }

  /// Null on a 404: a branch that never saved a document is not an error.
  Future<Map<String, dynamic>?> _getJson(Uri url, {required String what}) async {
    final client = _openClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(url);
      final res = await req.close().timeout(const Duration(seconds: 30));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode == 404) return null;
      if (res.statusCode != 200) {
        throw StateError('dishflow $what HTTP ${res.statusCode}: $text');
      }
      final decoded = jsonDecode(text);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } finally {
      client.close(force: true);
    }
  }
}
