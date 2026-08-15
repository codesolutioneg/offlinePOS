import 'dart:async';
import 'dart:convert';

import 'smtp_channel.dart';
import 'smtp_config.dart';

/// The server said no, or said nothing. Carries the reply so the settings screen
/// can show a shop owner what their provider actually answered instead of a
/// shrugging "could not send".
class SmtpFailure implements Exception {
  SmtpFailure(this.message);

  final String message;

  @override
  String toString() => 'SmtpFailure: $message';
}

/// How the client reaches a server. Injected so the conversation can be driven
/// without a listening port.
typedef SmtpConnect = Future<SmtpChannel> Function(SmtpConfig, Duration);

/// A small SMTP client: greet, authenticate, hand over one message, hang up.
///
/// Written here rather than pulled in because the till takes no new dependencies
/// and this is the whole of what a Z report needs: one recipient list, one plain
/// text part, no attachments, no queueing (the queue is a table, above this).
///
/// Nothing on a selling path ever touches it. It is called from the background
/// lane after a shift is closed, and every failure comes back as [SmtpFailure] for
/// the queue to retry.
class SmtpClient {
  const SmtpClient({
    this.timeout = const Duration(seconds: 20),
    SmtpConnect connect = openSocketChannel,
  }) : _connect = connect;

  /// Ceiling on any single step. A mail server that has stopped answering must not
  /// hold a socket open behind a shop that has gone home.
  final Duration timeout;

  final SmtpConnect _connect;

  Future<void> send(SmtpConfig config, EmailMessage message) async {
    if (message.to.isEmpty) return;
    final SmtpChannel channel;
    try {
      channel = await _connect(config, timeout);
    } on Object catch (e) {
      throw SmtpFailure('cannot reach ${config.host}:${config.port}: $e');
    }
    var session = _SmtpSession(channel, timeout);
    try {
      await session.expect(220);
      var caps = await _greet(session, config);
      if (config.security == SmtpSecurity.startTls) {
        await session.command('STARTTLS', 220);
        session = await session.upgrade(config.host);
        // The capability list before an upgrade is not binding, and AUTH is
        // routinely only offered once the connection is secure.
        caps = await _greet(session, config);
      }
      await _authenticate(session, config, caps);
      await session.command('MAIL FROM:<${config.from.trim()}>', 250);
      for (final to in message.to) {
        await session.command('RCPT TO:<${to.trim()}>', 250);
      }
      await session.command('DATA', 354);
      await session.write(_wire(config, message));
      await session.expect(250);
      // A refused QUIT does not un-send a message the server already took, so it
      // is sent and not checked.
      session.writeLine('QUIT');
    } finally {
      await session.close();
    }
  }

  /// EHLO, falling back to HELO for a server too old to know it. Returns the
  /// capability lines, uppercased, which is how AUTH support is discovered.
  Future<Set<String>> _greet(_SmtpSession session, SmtpConfig config) async {
    final reply = await session.send('EHLO ${_heloName(config)}');
    if (reply.code == 250) {
      return reply.lines.map((l) => l.toUpperCase()).toSet();
    }
    await session.command('HELO ${_heloName(config)}', 250);
    return const {};
  }

  /// What the till calls itself in the greeting. A bare domain is enough and no
  /// server that matters checks it, but an empty one is rejected outright.
  String _heloName(SmtpConfig config) {
    final at = config.from.indexOf('@');
    final domain = at < 0 ? '' : config.from.substring(at + 1).trim();
    return domain.isEmpty ? 'offlinepos' : domain;
  }

  Future<void> _authenticate(
      _SmtpSession session, SmtpConfig config, Set<String> caps) async {
    final user = config.username?.trim() ?? '';
    final password = config.password ?? '';
    // A relay inside the shop takes no login, and sending AUTH to one is an error
    // rather than a courtesy.
    if (user.isEmpty || password.isEmpty) return;
    final offersLogin = caps.any((c) => c.contains('AUTH') && c.contains('LOGIN'));
    if (offersLogin) {
      await session.command('AUTH LOGIN', 334);
      await session.command(base64.encode(utf8.encode(user)), 334);
      await session.command(base64.encode(utf8.encode(password)), 235);
      return;
    }
    // PLAIN is the fallback rather than the first choice: it puts the credential
    // on one line, which is worse to have sitting in a server log.
    final token = base64.encode(utf8.encode(authPlainToken(user, password)));
    await session.command('AUTH PLAIN $token', 235);
  }

  /// The AUTH PLAIN payload: an empty authorisation identity, the user and the
  /// password, separated by NUL. Exposed so a test can check the separator, which
  /// is invisible in the encoded form and wrong in every hand-written version of
  /// this that uses a space.
  static String authPlainToken(String user, String password) {
    const nul = '\u0000';
    return '$nul$user$nul$password';
  }

  /// The message on the wire: RFC 5322 headers then a base64 body.
  ///
  /// Base64 rather than raw text on purpose. A shop name, a tender label or a
  /// cashier's name can be Arabic, and it removes the dot-stuffing question
  /// entirely: no base64 line can begin with a full stop, so no line of a Z report
  /// can ever be read as the end of the message.
  static String _wire(SmtpConfig config, EmailMessage message) {
    final headers = [
      'From: <${config.from.trim()}>',
      'To: ${message.to.map((t) => '<${t.trim()}>').join(', ')}',
      'Subject: ${encodeHeader(message.subject)}',
      'Date: ${_rfc1123(DateTime.now())}',
      'MIME-Version: 1.0',
      'Content-Type: text/plain; charset=utf-8',
      'Content-Transfer-Encoding: base64',
    ];
    final body = base64.encode(utf8.encode(message.body));
    final wrapped = <String>[];
    for (var i = 0; i < body.length; i += 76) {
      wrapped.add(body.substring(i, i + 76 > body.length ? body.length : i + 76));
    }
    return '${headers.join('\r\n')}\r\n\r\n${wrapped.join('\r\n')}\r\n.\r\n';
  }

  /// A subject with anything outside plain ASCII goes out as an encoded word, or
  /// an Arabic shop name arrives as a row of question marks.
  static String encodeHeader(String value) {
    final isAscii = value.runes.every((r) => r >= 32 && r < 127);
    if (isAscii) return value;
    return '=?UTF-8?B?${base64.encode(utf8.encode(value))}?=';
  }

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// The date header, in the one format every mail server agrees on.
  static String _rfc1123(DateTime at) {
    final t = at.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${_days[t.weekday - 1]}, ${two(t.day)} ${_months[t.month - 1]} '
        '${t.year} ${two(t.hour)}:${two(t.minute)}:${two(t.second)} +0000';
  }
}

/// One reply from the server: the code and the text lines that carried it.
class _Reply {
  const _Reply(this.code, this.lines);
  final int code;
  final List<String> lines;

  String get text => lines.join(' ');
}

/// A channel with SMTP's line protocol on top of it.
///
/// Pull-based rather than a listener, because a reply has to be waited for
/// between commands.
class _SmtpSession {
  _SmtpSession(this._channel, this._timeout) {
    _sub = _channel.inbound.listen(
      (bytes) {
        _buffer += utf8.decode(bytes, allowMalformed: true);
        _drain();
      },
      onError: (Object e) => _fail('$e'),
      onDone: () => _fail('the server closed the connection'),
      cancelOnError: true,
    );
  }

  final SmtpChannel _channel;
  final Duration _timeout;
  late StreamSubscription<List<int>> _sub;
  String _buffer = '';
  Completer<_Reply>? _waiting;
  String? _error;
  bool _closed = false;

  /// Hand the connection to TLS and carry on speaking on the secured one. The
  /// subscription goes first: a socket being secured must have no listener, and
  /// nothing arrives between the 220 and the handshake for it to miss.
  Future<_SmtpSession> upgrade(String host) async {
    await _sub.cancel();
    try {
      final secure = await _channel.secure(host);
      // This wrapper is spent; the caller speaks on the one that comes back, and
      // closing this one would take the connection down with it.
      _closed = true;
      return _SmtpSession(secure, _timeout);
    } on Object catch (e) {
      throw SmtpFailure('STARTTLS refused by $host: $e');
    }
  }

  void writeLine(String line) => _channel.write('$line\r\n');

  Future<void> write(String data) async {
    _channel.write(data);
    await _channel.flush().timeout(_timeout);
  }

  /// Send a command and return the reply, whatever it is.
  Future<_Reply> send(String command) {
    final reply = _next();
    writeLine(command);
    return reply;
  }

  /// Send a command and insist on [expected], because every step of an SMTP
  /// conversation has exactly one answer that means "carry on".
  Future<void> command(String line, int expected) async {
    final reply = await send(line);
    if (reply.code != expected) {
      // The command is not echoed back: it can be a base64 credential.
      throw SmtpFailure('server answered ${reply.code}: ${reply.text}');
    }
  }

  Future<void> expect(int code) async {
    final reply = await _next();
    if (reply.code != code) {
      throw SmtpFailure('server answered ${reply.code}: ${reply.text}');
    }
  }

  Future<_Reply> _next() {
    final failure = _error;
    if (failure != null) throw SmtpFailure(failure);
    final waiting = Completer<_Reply>();
    _waiting = waiting;
    // Try what is already buffered first: a server can send the greeting and the
    // answer to a following command in one packet.
    _drain();
    return waiting.future.timeout(
      _timeout,
      onTimeout: () => throw SmtpFailure('no answer within ${_timeout.inSeconds}s'),
    );
  }

  /// Pull one complete reply out of the buffer. SMTP continues a reply with a
  /// hyphen after the code and ends it with a space, so the last line is the one
  /// that says the conversation may move on.
  void _drain() {
    final waiting = _waiting;
    if (waiting == null || waiting.isCompleted) return;
    final lines = <String>[];
    var consumed = 0;
    for (final raw in _buffer.split('\r\n')) {
      // A trailing fragment with no line ending yet is not a line.
      if (consumed + raw.length + 2 > _buffer.length) break;
      consumed += raw.length + 2;
      if (raw.length < 4) {
        lines.add(raw);
        continue;
      }
      lines.add(raw.substring(4));
      if (raw[3] == ' ') {
        _buffer = _buffer.substring(consumed);
        _waiting = null;
        waiting.complete(_Reply(int.tryParse(raw.substring(0, 3)) ?? 0, lines));
        return;
      }
    }
  }

  void _fail(String message) {
    _error = message;
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) {
      waiting.completeError(SmtpFailure(message));
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub.cancel();
    await _channel.close();
  }
}
