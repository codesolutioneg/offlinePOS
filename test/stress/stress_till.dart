import 'package:offline_pos/app/pos_session.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';

const kStressCash = PaymentMethod(id: 1, name: 'Cash', isCash: true);

/// One till on an in-memory database, wired the way `PosApp` wires a cashier's
/// session, so a stress run exercises the same code a real sale does.
class StressTill {
  StressTill({this.deviceId = 'till-1'}) : db = Db.open(':memory:') {
    ShiftStore(db).openShift(openingFloat: 0, cashierId: 'sara');
    orders = OrderStore(db, ownDeviceId: deviceId);
    settings = SettingsStore(db);
    outboxStore = SqliteOutboxStore(db);
    outbox = Outbox(store: outboxStore, senders: {});
    audit = AuditLog(db);
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: products,
      groups: const [],
      productGroupIds: const {},
      paymentMethods: const [kStressCash],
      refreshedAt: DateTime.now().toUtc(),
    );
  }

  final String deviceId;
  final Db db;
  late final OrderStore orders;
  late final SettingsStore settings;
  late final SqliteOutboxStore outboxStore;
  late final Outbox outbox;
  late final AuditLog audit;

  static final List<Product> products = [
    for (var i = 1; i <= 20; i++)
      Product(id: i, name: 'Item $i', price: 20.0 + i * 5, categoryId: 1),
  ];

  /// A cashier session with the same order-number rule `PosApp` installs: climb
  /// past the highest number already on the shop.
  PosSession session({String cashierId = 'sara'}) => PosSession(
        catalogue: CatalogueStore(db),
        orders: orders,
        outbox: outbox,
        audit: audit,
        deviceId: deviceId,
        cashierId: cashierId,
        nextOrderNo: () =>
            settings.nextOrderNumber(deviceId, atLeast: orders.orderNumberFloor()),
      );

  /// Ring [lines] different products onto the current order.
  void ring(PosSession s, {int lines = 4, int seed = 0}) {
    for (var i = 0; i < lines; i++) {
      s.addProduct(products[(seed + i) % products.length], qty: 1 + (i % 3).toDouble());
    }
  }

  /// Pay the current order in full cash.
  Order payCash(PosSession s) {
    final due = s.current.total;
    return s.pay(
      payments: [OrderPayment(methodId: kStressCash.id, amount: due)],
      cashReceived: due,
    )!;
  }

  void close() => db.close();
}