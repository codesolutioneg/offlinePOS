import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/email/email_outbox.dart';
import 'package:offline_pos/core/email/email_service.dart';
import 'package:offline_pos/core/email/smtp_client.dart';
import 'package:offline_pos/core/email/smtp_config.dart';

import '../db/sqlite_loader.dart';

const _config = SmtpConfig(
  host: 'mail.shop.example',
  port: 465,
  security: SmtpSecurity.ssl,
  from: 'till@shop.example',
  recipients: ['owner@shop.example'],
  username: 'till@shop.example',
  password: 'hunter2',
);

/// A mail server that can be turned off and on inside a test, the way one is at
/// 11pm when the shop's line is down.
class FlakyMail {
  bool down = false;
  final List<EmailMessage> sent = [];

  Future<void> send(SmtpConfig config, EmailMessage message) async {
    if (down) throw SmtpFailure('server down');
    sent.add(message);
  }
}

void main() {
  late Db db;
  late EmailOutbox queue;
  late FlakyMail mail;
  late DateTime clock;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    queue = EmailOutbox(db);
    mail = FlakyMail();
    clock = DateTime.utc(2026, 3, 1, 23);
  });
  tearDown(() => db.close());

  EmailService serviceWith({
    SmtpConfig? config = _config,
    Duration retryInterval = const Duration(minutes: 5),
    int maxAttempts = 3,
  }) =>
      EmailService(
        queue: queue,
        config: () => config,
        transport: mail.send,
        now: () => clock,
        retryInterval: retryInterval,
        maxAttempts: maxAttempts,
      );

  test('a report goes out when the line is up', () async {
    final service = serviceWith();
    await service.send(uuid: 'z-1', subject: 'Z report', body: 'Sales: 120');
    expect(mail.sent.single.subject, 'Z report');
    expect(mail.sent.single.to, ['owner@shop.example']);
    expect(service.pending, 0);
  });

  test('a report queued with the line down is not lost', () async {
    mail.down = true;
    final service = serviceWith();
    await service.send(uuid: 'z-1', subject: 'Z report', body: 'Sales: 120');
    expect(mail.sent, isEmpty);
    expect(service.pending, 1, reason: 'the day is written down, not dropped');
    expect(service.lastError, contains('server down'));

    // The line comes back and the background lane finds it.
    mail.down = false;
    clock = clock.add(const Duration(minutes: 6));
    await service.flush();
    expect(mail.sent.single.subject, 'Z report');
    expect(service.pending, 0);
  });

  test('a queued report is not retried faster than the interval', () async {
    mail.down = true;
    final service = serviceWith();
    await service.send(uuid: 'z-1', subject: 'Z', body: 'x');
    mail.down = false;
    // The catch-up lane ticks every half a minute; the retry must not.
    await service.flush();
    await service.flush();
    expect(mail.sent, isEmpty);
    clock = clock.add(const Duration(minutes: 6));
    await service.flush();
    expect(mail.sent, hasLength(1));
  });

  test('a report stops being retried once it has been given up on', () async {
    mail.down = true;
    final service = serviceWith(maxAttempts: 3);
    await service.send(uuid: 'z-1', subject: 'Z', body: 'x');
    for (var i = 0; i < 5; i++) {
      clock = clock.add(const Duration(minutes: 6));
      await service.flush();
    }
    expect(service.pending, 0);
    expect(service.abandoned, 1,
        reason: 'kept as a record rather than deleted quietly');
    // Even with the server back, an abandoned message is not resurrected: it
    // would be last night's Z arriving in the middle of today's service.
    mail.down = false;
    clock = clock.add(const Duration(minutes: 6));
    await service.flush();
    expect(mail.sent, isEmpty);
  });

  test('the same report queued twice is one email', () async {
    mail.down = true;
    final service = serviceWith();
    await service.send(uuid: 'z-1', subject: 'Z', body: 'x');
    await service.send(uuid: 'z-1', subject: 'Z', body: 'x');
    expect(service.pending, 1);
    mail.down = false;
    clock = clock.add(const Duration(minutes: 6));
    await service.flush();
    expect(mail.sent, hasLength(1));
  });

  test('a till with no mail set up queues nothing at all', () async {
    final service = serviceWith(config: null);
    await service.send(uuid: 'z-1', subject: 'Z', body: 'x');
    expect(service.configured, isFalse);
    expect(service.pending, 0, reason: 'a queue nothing can ever drain is a leak');
    expect(mail.sent, isEmpty);
  });

  test('a transport that throws never escapes the service', () async {
    final service = EmailService(
      queue: queue,
      config: () => _config,
      transport: (_, __) async => throw StateError('something unexpected'),
      now: () => clock,
    );
    // No expectLater: the point is that this simply returns.
    await service.send(uuid: 'z-1', subject: 'Z', body: 'x');
    expect(service.pending, 1);
    expect(service.lastError, contains('something unexpected'));
  });

  test('the test button reports the failure instead of queueing it', () async {
    mail.down = true;
    final service = serviceWith();
    expect(await service.trySend(subject: 'Test', body: 'x'),
        contains('server down'));
    expect(service.pending, 0, reason: 'a test must not leave a message behind');
    mail.down = false;
    expect(await service.trySend(subject: 'Test', body: 'x'), isNull);
    expect(mail.sent.single.subject, 'Test');
  });

  test('the test button says what is missing when nothing is configured',
      () async {
    final service = serviceWith(config: null);
    expect(await service.trySend(subject: 'Test', body: 'x'), isNotNull);
  });

  test('delivered mail is prunable and pending mail is not', () {
    queue.add(
      uuid: 'old',
      message: const EmailMessage(to: ['a@b.c'], subject: 'old', body: 'x'),
      at: clock,
    );
    queue.add(
      uuid: 'new',
      message: const EmailMessage(to: ['a@b.c'], subject: 'new', body: 'x'),
      at: clock,
    );
    queue.markSent('old', clock);
    queue.pruneSent(clock.add(const Duration(days: 1)));
    expect(queue.pendingCount(3), 1);
    expect(
      queue
          .due(
            now: clock,
            retryInterval: Duration.zero,
            maxAttempts: 3,
          )
          .single
          .message
          .subject,
      'new',
    );
  });
}
