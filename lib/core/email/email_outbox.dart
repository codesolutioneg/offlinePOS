import 'dart:convert';

import '../db/database.dart';
import 'smtp_config.dart';

/// One message waiting to go out, with how the attempts have gone.
class QueuedEmail {
  const QueuedEmail({
    required this.uuid,
    required this.message,
    required this.queuedAt,
    required this.attempts,
    this.lastAttemptAt,
    this.lastError,
  });

  final String uuid;
  final EmailMessage message;
  final DateTime queuedAt;
  final int attempts;
  final DateTime? lastAttemptAt;
  final String? lastError;
}

/// Mail written down before anybody tries to send it.
///
/// The same discipline as the order outbox and for the same reason: a shift close
/// happens at the end of a long day on a connection that may be down, and the
/// report cannot be something that only existed in memory while a socket failed.
///
/// Keyed on a uuid the caller chooses, so queueing the same Z report twice (a
/// close retried after a crash) is one message and not two.
class EmailOutbox {
  EmailOutbox(this._db);

  final Db _db;

  /// Writes the message down. Returns false when this uuid is already queued or
  /// already sent, which is what makes a repeat harmless.
  bool add({
    required String uuid,
    required EmailMessage message,
    required DateTime at,
  }) {
    final existing = _db.raw
        .select('SELECT 1 FROM email_outbox WHERE uuid = ? LIMIT 1', [uuid]);
    if (existing.isNotEmpty) return false;
    _db.raw.execute(
      'INSERT INTO email_outbox (uuid, recipients, subject, body, queued_at) '
      'VALUES (?,?,?,?,?)',
      [
        uuid,
        jsonEncode(message.to),
        message.subject,
        message.body,
        at.toUtc().toIso8601String(),
      ],
    );
    return true;
  }

  /// What is worth trying right now: never sent, not out of attempts, and not
  /// tried within [retryInterval]. Oldest first, so a backlog leaves in the order
  /// the shop made it.
  List<QueuedEmail> due({
    required DateTime now,
    required Duration retryInterval,
    required int maxAttempts,
  }) {
    final rows = _db.raw.select(
      'SELECT * FROM email_outbox WHERE sent_at IS NULL AND attempts < ? '
      'ORDER BY queued_at',
      [maxAttempts],
    );
    return [
      for (final r in rows)
        if (_isDue(r, now, retryInterval)) _read(r),
    ];
  }

  bool _isDue(Map<String, dynamic> row, DateTime now, Duration retryInterval) {
    final last = row['last_attempt_at'] as String?;
    if (last == null) return true;
    final at = DateTime.tryParse(last);
    return at == null || now.toUtc().difference(at) >= retryInterval;
  }

  void markSent(String uuid, DateTime at) => _db.raw.execute(
        'UPDATE email_outbox SET sent_at = ?, last_attempt_at = ?, last_error = NULL '
        'WHERE uuid = ?',
        [at.toUtc().toIso8601String(), at.toUtc().toIso8601String(), uuid],
      );

  void markFailed(String uuid, String error, DateTime at) => _db.raw.execute(
        'UPDATE email_outbox SET attempts = attempts + 1, last_attempt_at = ?, '
        'last_error = ? WHERE uuid = ?',
        [at.toUtc().toIso8601String(), error, uuid],
      );

  /// Still trying. [maxAttempts] is the caller's ceiling rather than a constant
  /// here, so the count and the sender can never disagree about what is still
  /// being tried.
  int pendingCount(int maxAttempts) => _count(
      'SELECT COUNT(*) AS n FROM email_outbox WHERE sent_at IS NULL AND attempts < ?',
      [maxAttempts]);

  /// Given up on. Kept rather than deleted: a report that never went is worth
  /// being able to see, and the settings screen says so.
  int abandonedCount(int maxAttempts) => _count(
      'SELECT COUNT(*) AS n FROM email_outbox WHERE sent_at IS NULL AND attempts >= ?',
      [maxAttempts]);

  /// The most recent failure, for the settings screen to read back.
  String? get lastError {
    final rows = _db.raw.select(
      'SELECT last_error FROM email_outbox WHERE last_error IS NOT NULL '
      'ORDER BY last_attempt_at DESC LIMIT 1',
    );
    return rows.isEmpty ? null : rows.first['last_error'] as String?;
  }

  /// Delivered mail older than [before] is no longer evidence of anything.
  void pruneSent(DateTime before) => _db.raw.execute(
      'DELETE FROM email_outbox WHERE sent_at IS NOT NULL AND sent_at < ?',
      [before.toUtc().toIso8601String()]);

  int _count(String sql, List<Object?> args) {
    final rows = _db.raw.select(sql, args);
    return rows.isEmpty ? 0 : (rows.first['n'] as int);
  }

  /// The default attempt ceiling, for a caller that has no opinion. Twelve tries
  /// five minutes apart covers an hour of a provider being down, which is the
  /// realistic case; a wrong password is not fixed by trying it four hundred more
  /// times.
  static const int maxAttemptsCeiling = 12;

  QueuedEmail _read(Map<String, dynamic> r) => QueuedEmail(
        uuid: r['uuid'] as String,
        message: EmailMessage(
          to: [
            for (final t in jsonDecode(r['recipients'] as String) as List)
              t.toString(),
          ],
          subject: r['subject'] as String,
          body: r['body'] as String,
        ),
        queuedAt: DateTime.parse(r['queued_at'] as String),
        attempts: r['attempts'] as int,
        lastAttemptAt: r['last_attempt_at'] == null
            ? null
            : DateTime.tryParse(r['last_attempt_at'] as String),
        lastError: r['last_error'] as String?,
      );
}
