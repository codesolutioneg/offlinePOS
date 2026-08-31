import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/catalogue.dart';

import '../db/sqlite_loader.dart';

/// A refresh must never leave a till unable to name a tender.
///
/// The tender read is optional, and a server that refuses it (the integration user
/// missing the Point of Sale group is the usual reason) looks from here exactly
/// like a shop with no methods at all. Taking that at face value would wipe the
/// methods the till has been selling with and book every sale as cash.
void main() {
  late Db db;
  late CatalogueStore cat;
  late SqliteOutboxStore outboxStore;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    cat = CatalogueStore(db);
    outboxStore = SqliteOutboxStore(db);
    cat.replaceAll(
      categories: const [Category(id: 1, name: 'Pizza')],
      products: const [Product(id: 10, name: 'Margherita', price: 250, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      paymentMethods: [
        PaymentMethod.journal(journalId: 11, name: 'Cash drawer', type: 'cash'),
        PaymentMethod.journal(journalId: 12, name: 'Bank CIB', type: 'bank'),
      ],
      refreshedAt: DateTime.now().toUtc(),
    );
  });
  tearDown(() => db.close());

  SyncService syncing(OdooPuller puller) {
    final outbox = Outbox(store: outboxStore, senders: {});
    return SyncService(
      outbox: outbox,
      catalogue: cat,
      outboxStore: outboxStore,
      deviceId: 'till-1',
      appVersion: 'test',
      puller: puller,
    );
  }

  /// A menu that always lands, with the tender question answered by [journals].
  OdooPuller puller({Object? journals}) => OdooPuller(
        call: (model, method, args, kwargs) async {
          switch (model) {
            case 'product.product':
              return [
                {
                  'id': 10, 'display_name': 'Margherita', 'lst_price': 250,
                  'pos_categ_ids': const <int>[], 'active': true,
                }
              ];
            case 'account.journal':
              if (journals is Exception) throw journals;
              return journals ?? const [];
            default:
              return const [];
          }
        },
      );

  test('a refused tender read does not wipe the configured methods', () async {
    await syncing(puller(journals: Exception('Access denied'))).refresh(force: true);

    expect(cat.paymentMethods().map((m) => m.name), ['Cash drawer', 'Bank CIB'],
        reason: 'losing these leaves every sale to book as cash, which counts the '
            'drawer over by every card sale of the day');
    // The refresh itself worked: the menu is what a refused tender read must not
    // cost the shop.
    expect(cat.products(), isNotEmpty);
  });

  test('an answered read does replace them', () async {
    await syncing(puller(
      journals: const [
        {'id': 12, 'name': 'Bank CIB', 'type': 'bank'},
      ],
    )).refresh(force: true);

    final saved = cat.paymentMethods();
    expect(saved.map((m) => m.name), ['Bank CIB']);
    // The journal survives the round trip through the till's own storage, so the
    // settings list can still say what the tender books to with the line down.
    expect(saved.single.id, -12);
    expect(saved.single.journalId, 12);
    expect(saved.single.journalType, 'bank');
  });
}
