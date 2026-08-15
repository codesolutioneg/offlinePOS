/// How the outgoing mail server is reached.
///
/// A shop's own mailbox, typed in once. The password sits in the settings table
/// like everything else on this till, which is a SQLCipher database encrypted at
/// rest, and it never leaves the device except to the server it belongs to.
enum SmtpSecurity {
  /// No transport security. Only ever right for a mail relay inside the shop.
  none('none'),

  /// TLS from the first byte, the usual port 465 arrangement.
  ssl('ssl'),

  /// Plain connection upgraded with STARTTLS, the usual port 587 arrangement.
  startTls('starttls');

  const SmtpSecurity(this.key);

  /// Stored on disk, so it is frozen once shipped.
  final String key;

  static SmtpSecurity fromKey(String? key) => switch (key) {
        'none' => SmtpSecurity.none,
        'starttls' => SmtpSecurity.startTls,
        _ => SmtpSecurity.ssl,
      };
}

class SmtpConfig {
  const SmtpConfig({
    required this.host,
    required this.port,
    required this.security,
    required this.from,
    required this.recipients,
    this.username,
    this.password,
  });

  final String host;
  final int port;
  final SmtpSecurity security;

  /// The address the report comes from. Most servers refuse a sender they do not
  /// own, so this is usually the same as [username].
  final String from;

  /// Who the Z report goes to. Empty means nothing is sent, which is the correct
  /// default: a shop that has not asked for mail gets none.
  final List<String> recipients;

  final String? username;
  final String? password;

  /// Whether there is enough here to attempt a send at all. Checked before
  /// queueing, so a till with no mail set up never grows a queue it can never
  /// drain.
  bool get isComplete =>
      host.trim().isNotEmpty &&
      port > 0 &&
      from.trim().isNotEmpty &&
      recipients.isNotEmpty;

  /// The port a shop should be offered for [security], since almost nobody knows
  /// theirs and the three conventions are near universal.
  static int defaultPortFor(SmtpSecurity security) => switch (security) {
        SmtpSecurity.ssl => 465,
        SmtpSecurity.startTls => 587,
        SmtpSecurity.none => 25,
      };
}

/// One message, already addressed. Plain text: a Z report is a column of figures
/// and nobody needs it in HTML.
class EmailMessage {
  const EmailMessage({
    required this.to,
    required this.subject,
    required this.body,
  });

  final List<String> to;
  final String subject;
  final String body;
}
