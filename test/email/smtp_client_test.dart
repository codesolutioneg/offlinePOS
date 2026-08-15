import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/email/smtp_channel.dart';
import 'package:offline_pos/core/email/smtp_client.dart';
import 'package:offline_pos/core/email/smtp_config.dart';

/// A mail server that answers the way a real one does, over an in-memory pipe.
///
/// Not a socket. The conversation is what matters here, and a test that needs a
/// listening port fails on a busy machine for reasons that have nothing to do
/// with mail.
class FakeSmtpServer implements SmtpChannel {
  FakeSmtpServer({this.mailFromCode = 250, this.offerAuth = true}) {
    // The greeting is already waiting when the client starts listening.
    _say('220 fake ESMTP');
  }

  /// What to answer MAIL FROM with, for the refusal case.
  final int mailFromCode;

  /// Whether EHLO advertises AUTH LOGIN. Off exercises the PLAIN fallback.
  final bool offerAuth;

  /// Every command line the client sent, in order, credentials included: this is
  /// a test double, and checking what was sent is the point.
  final List<String> commands = [];

  /// The DATA payload of the message, as received.
  String? data;

  bool closed = false;
  bool secured = false;

  /// Buffers whatever it is told before anyone listens, so the greeting written
  /// in the constructor is still there when the client subscribes.
  StreamController<List<int>> _out = StreamController<List<int>>();
  String _partial = '';
  bool _inData = false;
  int _authStep = 0;
  final StringBuffer _body = StringBuffer();

  @override
  Stream<List<int>> get inbound => _out.stream;

  void _say(String line) => _out.add(utf8.encode('$line\r\n'));

  @override
  void write(String data) {
    _partial += data;
    while (_partial.contains('\r\n')) {
      final at = _partial.indexOf('\r\n');
      final line = _partial.substring(0, at);
      _partial = _partial.substring(at + 2);
      _handle(line);
    }
  }

  void _handle(String line) {
    if (_inData) {
      if (line == '.') {
        _inData = false;
        data = _body.toString();
        _say('250 OK queued');
        return;
      }
      _body.writeln(line);
      return;
    }
    if (_authStep == 1) {
      commands.add(line);
      _authStep = 2;
      _say('334 UGFzc3dvcmQ6');
      return;
    }
    if (_authStep == 2) {
      commands.add(line);
      _authStep = 0;
      _say('235 authenticated');
      return;
    }
    commands.add(line);
    final upper = line.toUpperCase();
    if (upper.startsWith('EHLO')) {
      _say(offerAuth
          ? '250-fake greets you\r\n250 AUTH LOGIN PLAIN'
          : '250 fake greets you');
    } else if (upper == 'STARTTLS') {
      _say('220 go ahead');
    } else if (upper.startsWith('AUTH LOGIN')) {
      _authStep = 1;
      _say('334 VXNlcm5hbWU6');
    } else if (upper.startsWith('AUTH PLAIN')) {
      _say('235 authenticated');
    } else if (upper.startsWith('MAIL FROM')) {
      _say('$mailFromCode ${mailFromCode == 250 ? 'OK' : 'mailbox unavailable'}');
    } else if (upper == 'DATA') {
      _inData = true;
      _say('354 go ahead');
    } else {
      _say('250 OK');
    }
  }

  @override
  Future<void> flush() async {}

  @override
  Future<SmtpChannel> secure(String host) async {
    secured = true;
    // A real server starts the conversation again on the secured connection, and
    // the client subscribes to it again with it.
    _out = StreamController<List<int>>();
    return this;
  }

  @override
  Future<void> close() async {
    closed = true;
    await _out.close();
  }
}

void main() {
  const config = SmtpConfig(
    host: 'mail.shop.example',
    port: 587,
    security: SmtpSecurity.none,
    from: 'till@shop.example',
    recipients: ['owner@shop.example'],
    username: 'till@shop.example',
    password: 'hunter2',
  );

  /// A client wired to [server] instead of a socket.
  SmtpClient clientFor(FakeSmtpServer server) =>
      SmtpClient(connect: (_, __) async => server);

  /// The body a shop owner would actually read.
  String bodyOf(String wire) {
    final lines = wire.split('\n').map((l) => l.trimRight()).toList();
    final blank = lines.indexOf('');
    return utf8.decode(base64.decode(lines.sublist(blank + 1).join().trim()));
  }

  String headerOf(String wire, String name) => wire
      .split('\n')
      .firstWhere((l) => l.startsWith('$name: '))
      .substring(name.length + 2)
      .trim();

  test('a message goes through the whole conversation in order', () async {
    final server = FakeSmtpServer();
    await clientFor(server).send(
      config,
      const EmailMessage(
        to: ['owner@shop.example'],
        subject: 'Z report',
        body: 'Sales: 120.00',
      ),
    );

    expect(server.commands.first, startsWith('EHLO'));
    expect(server.commands, contains('AUTH LOGIN'));
    expect(server.commands, contains('MAIL FROM:<till@shop.example>'));
    expect(server.commands, contains('RCPT TO:<owner@shop.example>'));
    expect(server.commands, contains('DATA'));
    expect(server.commands, contains('QUIT'));
    expect(server.closed, isTrue, reason: 'the connection is not left open');
    expect(headerOf(server.data!, 'Subject'), 'Z report');
    expect(server.data, contains('Content-Transfer-Encoding: base64'));
    expect(bodyOf(server.data!), 'Sales: 120.00');
  });

  test('the login is base64, username then password', () async {
    final server = FakeSmtpServer();
    await clientFor(server).send(
      config,
      const EmailMessage(to: ['owner@shop.example'], subject: 'Z', body: 'x'),
    );
    final at = server.commands.indexOf('AUTH LOGIN');
    expect(utf8.decode(base64.decode(server.commands[at + 1])), 'till@shop.example');
    expect(utf8.decode(base64.decode(server.commands[at + 2])), 'hunter2');
  });

  test('a server that does not offer AUTH LOGIN gets PLAIN, NUL separated',
      () async {
    final server = FakeSmtpServer(offerAuth: false);
    await clientFor(server).send(
      config,
      const EmailMessage(to: ['owner@shop.example'], subject: 'Z', body: 'x'),
    );
    final plain =
        server.commands.firstWhere((c) => c.startsWith('AUTH PLAIN '));
    final decoded =
        utf8.decode(base64.decode(plain.substring('AUTH PLAIN '.length)));
    expect(decoded, SmtpClient.authPlainToken('till@shop.example', 'hunter2'));
    // The separator is invisible in the encoded form and is a space in every
    // hand-written version of this that does not work.
    expect(decoded.codeUnits.where((c) => c == 0).length, 2);
  });

  test('a relay that needs no login is not sent one', () async {
    final server = FakeSmtpServer();
    await clientFor(server).send(
      const SmtpConfig(
        host: 'relay.shop.local',
        port: 25,
        security: SmtpSecurity.none,
        from: 'till@shop.example',
        recipients: ['owner@shop.example'],
      ),
      const EmailMessage(to: ['owner@shop.example'], subject: 'Z', body: 'x'),
    );
    expect(server.commands.any((c) => c.startsWith('AUTH')), isFalse);
  });

  test('an Arabic subject and body survive the trip', () async {
    final server = FakeSmtpServer();
    await clientFor(server).send(
      config,
      const EmailMessage(
        to: ['owner@shop.example'],
        subject: 'تقرير Z',
        body: 'المبيعات: 120.00',
      ),
    );
    final subject = headerOf(server.data!, 'Subject');
    expect(subject, startsWith('=?UTF-8?B?'));
    expect(
      utf8.decode(base64
          .decode(subject.substring('=?UTF-8?B?'.length, subject.length - 2))),
      'تقرير Z',
    );
    expect(bodyOf(server.data!), 'المبيعات: 120.00');
  });

  test('every recipient gets its own RCPT', () async {
    final server = FakeSmtpServer();
    await clientFor(server).send(
      config,
      const EmailMessage(
        to: ['a@shop.example', 'b@shop.example'],
        subject: 'Z',
        body: 'x',
      ),
    );
    expect(server.commands.where((c) => c.startsWith('RCPT TO')).length, 2);
  });

  test('a refusal comes back carrying what the server said', () async {
    final server = FakeSmtpServer(mailFromCode: 550);
    await expectLater(
      clientFor(server).send(
        config,
        const EmailMessage(to: ['owner@shop.example'], subject: 'Z', body: 'x'),
      ),
      throwsA(isA<SmtpFailure>()
          .having((e) => e.message, 'message', contains('550'))),
    );
    expect(server.closed, isTrue, reason: 'a refusal still hangs up');
  });

  test('a server that cannot be reached is a failure, not a hang', () async {
    final client = SmtpClient(
      connect: (_, __) async => throw const SocketFailure(),
    );
    await expectLater(
      client.send(
        config,
        const EmailMessage(to: ['owner@shop.example'], subject: 'Z', body: 'x'),
      ),
      throwsA(isA<SmtpFailure>()
          .having((e) => e.message, 'message', contains('cannot reach'))),
    );
  });

  test('STARTTLS upgrades before the login is sent', () async {
    final server = FakeSmtpServer();
    await clientFor(server).send(
      const SmtpConfig(
        host: 'mail.shop.example',
        port: 587,
        security: SmtpSecurity.startTls,
        from: 'till@shop.example',
        recipients: ['owner@shop.example'],
        username: 'till@shop.example',
        password: 'hunter2',
      ),
      const EmailMessage(to: ['owner@shop.example'], subject: 'Z', body: 'x'),
    );
    expect(server.secured, isTrue);
    expect(server.commands.indexOf('STARTTLS'),
        lessThan(server.commands.indexOf('AUTH LOGIN')),
        reason: 'a password must never go out in the clear');
  });

  test('a message with nobody to send it to is not sent at all', () async {
    final server = FakeSmtpServer();
    await clientFor(server)
        .send(config, const EmailMessage(to: [], subject: 'Z', body: 'x'));
    expect(server.commands, isEmpty);
  });
}

/// Stands in for whatever dart:io throws when the host is not there.
class SocketFailure implements Exception {
  const SocketFailure();
  @override
  String toString() => 'no route to host';
}
