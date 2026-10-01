import 'package:offline_pos/app/pos_session.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/stress_purge.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/features/dev/scenario/stress_deps.dart';

import 'stress_till.dart';

/// A cashier session on [till] that marks every order it creates as a lab order,
/// the way `PosApp` builds the Stress Lab's sessions.
PosSession labSession(StressTill till, String cashierId) => PosSession(
  catalogue: CatalogueStore(till.db),
  orders: till.orders,
  outbox: till.outbox,
  audit: till.audit,
  deviceId: till.deviceId,
  cashierId: cashierId,
  settings: till.settings,
  nextOrderNo: () => till.settings.nextOrderNumber(
    till.deviceId,
    atLeast: till.orders.orderNumberFloor(),
  ),
  shiftOpenedAt: () => till.shifts.currentOpenShift()?.openedAt,
  tagOrder: (o) => o.note = kStressNote,
);

/// What a full-day run needs from [till], with no printers attached.
StressDeps labDeps(StressTill till) => StressDeps(
  db: till.db,
  deviceId: till.deviceId,
  orders: till.orders,
  tables: TableStore(till.db),
  catalogue: CatalogueStore(till.db),
  newSession: (id) => labSession(till, id),
);
