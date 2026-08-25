import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/db_key.dart';

/// A keychain that answers nothing until it has been asked [readyOn] times, which
/// is a till opening while the machine is still booting.
class LateKeyStore implements KeyStore {
  LateKeyStore({required this.readyOn, this.throws = false});

  final int readyOn;
  final bool throws;
  int reads = 0;
  String? held;
  int writes = 0;

  @override
  Future<String?> read() async {
    reads++;
    if (reads < readyOn) {
      if (throws) throw StateError('the credential store is not up yet');
      return null;
    }
    return held;
  }

  @override
  Future<void> write(String key) async {
    writes++;
    held = key;
  }
}

void main() {
  Future<void> noWait(Duration _) async {}

  test('a fresh till still gets a key on the first ask', () async {
    final store = LateKeyStore(readyOn: 1);

    final key = await DbKey(store).getOrCreate(wait: noWait);

    expect(key.length, 64);
    expect(store.reads, 1);
    expect(store.writes, 1);
  });

  test('a key that arrives late is waited for rather than replaced', () async {
    final store = LateKeyStore(readyOn: 3)..held = 'a' * 64;

    final key = await DbKey(store).getOrCreate(databaseExists: true, wait: noWait);

    expect(key, 'a' * 64, reason: 'the existing key must be the one used');
    expect(store.writes, 0, reason: 'writing here would strand the existing sales');
  });

  test('a keychain that throws before it is up is asked again, not believed', () async {
    final store = LateKeyStore(readyOn: 3, throws: true)..held = 'b' * 64;

    final key = await DbKey(store).getOrCreate(databaseExists: true, wait: noWait);

    expect(key, 'b' * 64);
    expect(store.writes, 0);
  });

  test('a key that never comes is refused, never replaced', () async {
    final store = LateKeyStore(readyOn: 99);

    await expectLater(
      DbKey(store).getOrCreate(databaseExists: true, attempts: 4, wait: noWait),
      throwsA(isA<MissingDatabaseKey>()),
    );
    expect(store.reads, 4, reason: 'it must actually retry before giving up');
    expect(
      store.writes,
      0,
      reason: 'a new key over an existing database is permanent data loss',
    );
  });

  test('waiting is what the retries are for', () async {
    final store = LateKeyStore(readyOn: 3)..held = 'c' * 64;
    final waited = <Duration>[];

    await DbKey(store).getOrCreate(
      databaseExists: true,
      retryAfter: const Duration(seconds: 2),
      wait: (d) async => waited.add(d),
    );

    expect(waited, [const Duration(seconds: 2), const Duration(seconds: 2)]);
  });
}
