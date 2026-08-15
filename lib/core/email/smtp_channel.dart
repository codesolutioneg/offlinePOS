import 'dart:async';
import 'dart:io';

import 'smtp_config.dart';

/// A byte pipe to a mail server.
///
/// The socket sits behind this interface for one reason: an SMTP conversation is
/// a sequence of codes and replies, and that is the part worth testing. A test
/// that needs a listening port to check whether the client says RCPT TO twice is
/// a test that fails on a busy machine for reasons that have nothing to do with
/// mail.
abstract class SmtpChannel {
  /// Everything the server has said. Subscribed to exactly once.
  Stream<List<int>> get inbound;

  void write(String data);

  Future<void> flush();

  /// Hand the connection to TLS, for STARTTLS. The caller has already stopped
  /// listening: a socket being secured must have nothing subscribed to it.
  Future<SmtpChannel> secure(String host);

  Future<void> close();
}

/// Opens the real thing.
///
/// Implicit TLS connects secured from the first byte; the other two modes connect
/// in the clear, and STARTTLS upgrades afterwards.
Future<SmtpChannel> openSocketChannel(SmtpConfig config, Duration timeout) async {
  final socket = config.security == SmtpSecurity.ssl
      ? await SecureSocket.connect(config.host, config.port, timeout: timeout)
      : await Socket.connect(config.host, config.port, timeout: timeout);
  return SocketSmtpChannel(socket);
}

class SocketSmtpChannel implements SmtpChannel {
  SocketSmtpChannel(this._socket);

  final Socket _socket;

  @override
  Stream<List<int>> get inbound => _socket;

  @override
  void write(String data) => _socket.write(data);

  @override
  Future<void> flush() => _socket.flush();

  @override
  Future<SmtpChannel> secure(String host) async =>
      SocketSmtpChannel(await SecureSocket.secure(_socket, host: host));

  @override
  Future<void> close() async => _socket.destroy();
}
