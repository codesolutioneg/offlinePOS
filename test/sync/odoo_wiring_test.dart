import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_sender.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';

class MemStore implements OutboxStore {
  final List<OutboxEntry> e = [];
  final Set<int> sent = {};
  final Map<int,String> dead = {};
  int _n = 1;
  @override Future<void> append(String k, String u, Map<String,dynamic> p) async => e.add(OutboxEntry(id:_n++,kind:k,payloadUuid:u,payload:p));
  @override Future<List<OutboxEntry>> pending({int limit=20}) async => e.where((x)=>!sent.contains(x.id)&&!dead.containsKey(x.id)).take(limit).toList();
  @override Future<void> markSent(int id) async => sent.add(id);
  @override Future<void> markFailed(int id, String err) async {}
  @override Future<void> markDead(int id, String r) async => dead[id]=r;
}

void main() {
  test('an unconfigured wiring keeps a sale queued, never parks it', () async {
    final store = MemStore();
    final outbox = Outbox(store: store, senders: {});
    OdooWiring(outbox: outbox); // built but not configured
    await outbox.enqueue('order.push', 'u1', {'uuid':'u1'});
    // No sender registered => drain skips it, leaves it pending, does not dead-letter.
    expect(await outbox.drain(), 0);
    expect(store.dead, isEmpty);
    expect((await store.pending()).single.payloadUuid, 'u1');
  });

  test('configuring registers a sender that authenticates then books', () async {
    final store = MemStore();
    final outbox = Outbox(store: store, senders: {});
    var authed = false;
    final booked = <String>[];
    Future<HttpReply> fake(Uri u, Map<String,String> h, String b) async {
      if (u.path.contains('authenticate')) { authed = true; return HttpReply(200, '{"result":{"uid":2}}', headers: const {'set-cookie':'session_id=abc; Path=/'}); }
      booked.add('x'); return HttpReply(200, '{"result":[{"status":"created","id":9}]}');
    }
    final wiring = OdooWiring(outbox: outbox, post: fake);
    wiring.configure(const OdooEndpoint(baseUrl:'https://s', db:'d', login:'u', password:'p'));
    await outbox.enqueue('order.push', 'u1', {'uuid':'u1'});
    expect(await outbox.drain(), 1);
    expect(authed, isTrue);
    expect(booked, isNotEmpty);
  });

  test('disable stops pushing so a mispointed till queues instead', () async {
    final store = MemStore();
    final outbox = Outbox(store: store, senders: {});
    final wiring = OdooWiring(outbox: outbox, post: (u,h,b) async => HttpReply(200,'{"result":{"uid":2}}'));
    wiring.configure(const OdooEndpoint(baseUrl:'https://s', db:'d', login:'u'));
    wiring.disable();
    await outbox.enqueue('order.push', 'u1', {'uuid':'u1'});
    expect(await outbox.drain(), 0);
    expect(store.dead, isEmpty);
  });
}
