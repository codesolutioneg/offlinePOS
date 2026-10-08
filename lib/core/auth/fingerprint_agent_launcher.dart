import 'dart:io';

/// Starts [tools/start_zk_agent.bat] when nothing answers on 127.0.0.1:9201.
///
/// Windows only. The bat runs [zk_setup_check.py] first (pip + DLLs + optional
/// USB driver) and writes status under %LOCALAPPDATA%\OfflinePOS\ for tracking.
class FingerprintAgentLauncher {
  FingerprintAgentLauncher({this.port = 9201});

  final int port;

  /// True when something accepts TCP on localhost:[port].
  Future<bool> isListening() async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 400),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Path to [start_zk_agent.bat], or null if the tools folder is missing.
  String? resolveBatPath() => _resolveBat()?.path;

  /// Spawn the silent bat next to the exe (or from the repo tools/ in debug).
  ///
  /// When [runSetup] is true (default), waits longer so pip install can finish
  /// on a fresh PC.
  Future<bool> ensureRunning({bool runSetup = true}) async {
    if (!Platform.isWindows) return false;
    if (await isListening()) return true;

    final bat = _resolveBat();
    if (bat == null) return false;

    try {
      await Process.start(
        'cmd.exe',
        ['/c', 'start', '/MIN', '', bat.path, 'silent'],
        workingDirectory: bat.parent.path,
        mode: ProcessStartMode.detached,
      );
      // Fresh PC: pip + DLL copy can take >15s.
      final attempts = runSetup ? 60 : 15;
      for (var i = 0; i < attempts; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (await isListening()) return true;
      }
    } catch (_) {}
    return false;
  }

  File? _resolveBat() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final walked = _walkToToolsBat();
    final candidates = <String>[
      '$exeDir\\tools\\start_zk_agent.bat',
      '$exeDir\\start_zk_agent.bat',
      if (walked != null) walked,
    ];

    for (final path in candidates) {
      final f = File(path);
      if (f.existsSync()) return f;
    }
    return null;
  }

  String? _walkToToolsBat() {
    var dir = Directory(File(Platform.resolvedExecutable).parent.path);
    for (var i = 0; i < 8; i++) {
      final bat = File('${dir.path}\\tools\\start_zk_agent.bat');
      if (bat.existsSync()) return bat.path;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    const checkout = r'd:\offlinePOS\tools\start_zk_agent.bat';
    if (File(checkout).existsSync()) return checkout;
    return null;
  }
}
