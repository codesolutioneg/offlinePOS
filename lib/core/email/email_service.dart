import 'dart:async';

import '../audit/audit_log.dart';
import 'email_outbox.dart';
import 'smtp_config.dart';
import 'smtp_client.dart';

/// Hands a message to whatever can actually put it on a wire. Injected so the
/// service is testable without a mail server.
typedef EmailTransport = Future<void> Function(SmtpConfig, EmailMessage);

/// Sends the mail a shop asked for, and never gets in the way of the shop.
///
/// Two rules hold this together:
///
/// 1. Nothing here can fail a cash-up. [send] writes the message down and then
///    tries, and every failure is recorded rather than thrown. A closing cashier
///    is not the person to hand a mail server error to.
/// 2. Nothing here is on a selling path. The only callers are the shift close,
///    the background catch-up lane, and a manager pressing Send test.
class EmailService {
  EmailService({
    required EmailOutbox queue,
    required SmtpConfig? Function() config,
    EmailTransport? transport,
    AuditLog? audit,
    DateTime Function()? now,
    this.retryInterval = const Duration(minutes: 5),
    this.maxAttempts = EmailOutbox.maxAttemptsCeiling,
  })  : _queue = queue,
        _config = config,
        _transport = transport ?? const SmtpClient().send,
        _audit = audit,
        _now = now ?? DateTime.now;

  final EmailOutbox _queue;

  /// Read on every send rather than held: a manager who fixes the password
  /// mid-evening must not have to restart the till for the queue to use it.
  final SmtpConfig? Function() _config;

  final EmailTransport _transport;
  final AuditLog? _audit;
  final DateTime Function() _now;

  /// How long a failed message waits before the background lane tries it again.
  final Duration retryInterval;

  /// After this many failures the message stops being retried and is left in the
  /// queue as a record.
  final int maxAttempts;

  /// Whether there is a mail server and somebody to send to.
  bool get configured => _config()?.isComplete ?? false;

  int get pending => _queue.pendingCount(maxAttempts);
  int get abandoned => _queue.abandonedCount(maxAttempts);
  String? get lastError => _queue.lastError;

  /// Queue one message and try it once, now. Never throws.
  ///
  /// [uuid] makes the queue idempotent: the same Z report handed over twice is one
  /// message. Nothing is queued at all when there is no mail configured, so a shop
  /// that never asked for reports does not accumulate a queue it can never drain.
  Future<void> send({
    required String uuid,
    required String subject,
    required String body,
  }) async {
    final config = _config();
    if (config == null || !config.isComplete) return;
    try {
      final queued = _queue.add(
        uuid: uuid,
        message: EmailMessage(to: config.recipients, subject: subject, body: body),
        at: _now(),
      );
      if (!queued) return;
    } catch (e) {
      // Writing the message down is the one part that should not fail. If it
      // does, it is still not the cashier's problem: the drawer is counted and
      // the day is closed.
      _audit?.record('system', 'email.queue.failed', detail: '$e');
      return;
    }
    await flush();
  }

  /// Try everything that is due. Called from the background lane, so a report
  /// queued while the line was down goes out on its own once it is back.
  Future<void> flush() async {
    final config = _config();
    if (config == null || !config.isComplete) return;
    final due = _queue.due(
      now: _now(),
      retryInterval: retryInterval,
      maxAttempts: maxAttempts,
    );
    for (final entry in due) {
      try {
        await _transport(config, entry.message);
        _queue.markSent(entry.uuid, _now());
        _audit?.record('system', 'email.sent', detail: entry.message.subject);
      } catch (e) {
        final attempt = entry.attempts + 1;
        _queue.markFailed(entry.uuid, _reasonOf(e), _now());
        if (attempt >= maxAttempts) {
          // Said out loud once, at the point it stops trying. A queue that
          // silently gave up is the thing support cannot see.
          _audit?.record('system', 'email.abandoned',
              detail: '${entry.message.subject}: ${_reasonOf(e)}');
        }
      }
    }
  }

  /// Send one message straight out, bypassing the queue, and let the caller see
  /// what happened. Only for the Send test button: a test that quietly queued
  /// itself would tell a manager nothing about whether the settings work.
  Future<String?> trySend({
    required String subject,
    required String body,
  }) async {
    final config = _config();
    if (config == null || !config.isComplete) {
      return 'Fill in the server, the sender and at least one recipient first.';
    }
    try {
      await _transport(
        config,
        EmailMessage(to: config.recipients, subject: subject, body: body),
      );
      return null;
    } catch (e) {
      return _reasonOf(e);
    }
  }

  /// What went wrong, in words worth showing. The message body is never included:
  /// it is a day's takings and it does not belong in an error string.
  static String _reasonOf(Object e) =>
      e is SmtpFailure ? e.message : e.toString();
}
