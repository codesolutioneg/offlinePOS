import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';

import 'sqlite_loader.dart';

void main() {
  setUpAll(useSystemSqlite);

  test('a moment of contention is waited out rather than fatal', () {
    final db = Db.open(':memory:');

    final timeout = db.raw.select('PRAGMA busy_timeout').first.values.first;

    expect(
      timeout,
      5000,
      reason: 'at the default of zero, another connection still letting go of '
          'the file makes a launch fail outright',
    );
    db.close();
  });
}
