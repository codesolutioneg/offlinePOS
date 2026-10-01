import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/ecommerce_orders_client.dart';

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.statusCode, String body)
      : _bytes = utf8.encode(body);

  final List<int> _bytes;
  @override
  final int statusCode;

  @override
  int get contentLength => _bytes.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  HttpHeaders get headers => _EmptyHeaders();
  @override
  bool get isRedirect => false;
  @override
  bool get persistentConnection => false;
  @override
  String get reasonPhrase => '';
  @override
  List<RedirectInfo> get redirects => const [];
  @override
  List<Cookie> get cookies => const [];
  @override
  X509Certificate? get certificate => null;
  @override
  HttpConnectionInfo? get connectionInfo => null;
  @override
  Future<Socket> detachSocket() => throw UnimplementedError();
  @override
  Future<HttpClientResponse> redirect(
          [String? method, Uri? url, bool? followRedirects]) =>
      throw UnimplementedError();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable([_bytes]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

class _EmptyHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this._response);

  final HttpClientResponse _response;
  final _chunks = <List<int>>[];

  @override
  HttpHeaders get headers => _EmptyHeaders();
  @override
  void add(List<int> data) => _chunks.add(data);
  @override
  Future<HttpClientResponse> close() async => _response;

  String get body => utf8.decode(_chunks.expand((c) => c).toList());

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeClient implements HttpClient {
  _FakeClient(this._onRequest);

  final Future<HttpClientResponse> Function(String method, Uri url, _FakeRequest req)
      _onRequest;
  _FakeRequest? lastRequest;
  Uri? lastUrl;
  String? lastMethod;

  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = Duration.zero;

  Future<HttpClientRequest> _open(String method, Uri url) async {
    lastMethod = method;
    lastUrl = url;
    final pending = _FakeRequest(_FakeResponse(200, '{}'));
    lastRequest = pending;
    // Resolve body after close — callers add then close.
    return _RecordingRequest(pending, () async {
      return _onRequest(method, url, pending);
    });
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _open('GET', url);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => _open('PATCH', url);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => _open('POST', url);
  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _RecordingRequest implements HttpClientRequest {
  _RecordingRequest(this._inner, this._onClose);

  final _FakeRequest _inner;
  final Future<HttpClientResponse> Function() _onClose;

  @override
  HttpHeaders get headers => _inner.headers;
  @override
  void add(List<int> data) => _inner.add(data);
  @override
  Future<HttpClientResponse> close() => _onClose();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  test('listActive parses runQuery rows and filters branch', () async {
    final client = _FakeClient((method, url, req) async {
      expect(method, 'POST');
      expect(url.path, contains('documents:runQuery'));
      return _FakeResponse(
        200,
        jsonEncode([
          {
            'document': {
              'name':
                  'projects/p/databases/(default)/documents/ecommerce_orders/a1',
              'fields': {
                'status': {'stringValue': 'pending'},
                'branchId': {'stringValue': 'b1'},
                'customer_name': {'stringValue': 'Ali'},
                'items': {
                  'arrayValue': {
                    'values': [
                      {
                        'mapValue': {
                          'fields': {
                            'name': {'stringValue': 'Burger'},
                            'quantity': {'integerValue': '1'},
                            'price_unit': {'doubleValue': 50},
                          }
                        }
                      }
                    ]
                  }
                },
              },
            },
          },
          {
            'document': {
              'name':
                  'projects/p/databases/(default)/documents/ecommerce_orders/a2',
              'fields': {
                'status': {'stringValue': 'pending'},
                'branchId': {'stringValue': 'other'},
                'items': {'arrayValue': {}},
              },
            },
          },
        ]),
      );
    });

    final orders = await EcommerceOrdersClient(openClient: () => client).listActive(
      projectId: 'p',
      apiKey: 'k',
      branchId: 'b1',
    );
    expect(orders, hasLength(1));
    expect(orders.single.id, 'a1');
    expect(orders.single.customerName, 'Ali');
  });

  test('tryClaim patches pending to received', () async {
    var gets = 0;
    final client = _FakeClient((method, url, req) async {
      if (method == 'GET') {
        gets++;
        return _FakeResponse(
          200,
          jsonEncode({
            'name':
                'projects/p/databases/(default)/documents/ecommerce_orders/e1',
            'fields': {
              'status': {'stringValue': 'pending'},
              'items': {'arrayValue': {}},
            },
          }),
        );
      }
      expect(method, 'PATCH');
      expect(url.query, contains('updateMask.fieldPaths'));
      final body = jsonDecode(req.body) as Map;
      final fields = body['fields'] as Map;
      expect(fields['status']['stringValue'], 'received');
      expect(fields['receivedBy']['stringValue'], 'c1');
      return _FakeResponse(200, '{}');
    });

    final ok = await EcommerceOrdersClient(openClient: () => client).tryClaim(
      projectId: 'p',
      apiKey: 'k',
      orderId: 'e1',
      cashierId: 'c1',
      cashierName: 'Sara',
    );
    expect(ok, isTrue);
    expect(gets, 1);
  });

  test('markCompleted patches status completed', () async {
    final client = _FakeClient((method, url, req) async {
      expect(method, 'PATCH');
      expect(url.path, contains('/ecommerce_orders/e9'));
      final body = jsonDecode(req.body) as Map;
      expect(body['fields']['status']['stringValue'], 'completed');
      return _FakeResponse(200, '{}');
    });

    final ok = await EcommerceOrdersClient(openClient: () => client).markCompleted(
      projectId: 'p',
      apiKey: 'k',
      orderId: 'e9',
    );
    expect(ok, isTrue);
  });
}
