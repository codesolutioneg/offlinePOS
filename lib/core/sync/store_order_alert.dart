import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Tracks seen `ecommerce_orders` ids so only *new* arrivals alert the till.
class StoreOrderWatchState {
  final Set<String> _known = {};
  bool _ready = false;

  bool get ready => _ready;
  Set<String> get known => Set.unmodifiable(_known);

  /// First snapshot is a silent baseline. Later snapshots return newly seen ids.
  Set<String> observe(Iterable<String> currentIds) {
    final current = currentIds.toSet();
    if (!_ready) {
      _known
        ..clear()
        ..addAll(current);
      _ready = true;
      return const {};
    }
    final neu = current.difference(_known);
    _known
      ..clear()
      ..addAll(current);
    return neu;
  }

  void reset() {
    _known.clear();
    _ready = false;
  }
}

/// Repeating till beep for store-order alerts (no audio package).
///
/// Uses [SystemSound] everywhere, plus a short generated WAV on Windows so the
/// counter hears something even when the OS alert is muted or soft.
class TillAlertSound {
  TillAlertSound._();

  static Timer? _timer;
  static String? _wavPath;
  static bool _playing = false;
  static bool _beepBusy = false;

  static bool get isPlaying => _playing;

  static Future<void> start() async {
    if (_playing) return;
    _playing = true;
    await _beepOnce();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 1400), (_) {
      unawaited(_beepOnce());
    });
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
    _playing = false;
  }

  static Future<void> _beepOnce() async {
    if (_beepBusy || !_playing) return;
    _beepBusy = true;
    try {
      try {
        await SystemSound.play(SystemSoundType.alert);
      } catch (_) {}
      if (!Platform.isWindows || !_playing) return;
      try {
        final path = await _ensureWav();
        // Play() returns immediately; PlaySync would stall the UI isolate.
        await Process.run(
          'powershell',
          [
            '-NoProfile',
            '-Command',
            '(New-Object Media.SoundPlayer "$path").Play()',
          ],
          runInShell: false,
        );
      } catch (_) {}
    } finally {
      _beepBusy = false;
    }
  }

  static Future<String> _ensureWav() async {
    if (_wavPath != null) return _wavPath!;
    final dir = await getTemporaryDirectory();
    final file =
        File('${dir.path}${Platform.pathSeparator}offlinepos_alert.wav');
    if (!await file.exists()) {
      await file.writeAsBytes(_wavBeep(), flush: true);
    }
    return _wavPath = file.path;
  }

  /// Short 880 Hz mono WAV — same idea as Dishflow's web kiosk beep.
  static Uint8List _wavBeep() {
    const sampleRate = 8000;
    const durationMs = 220;
    final n = (sampleRate * durationMs / 1000).round();
    final pcm = Uint8List(n);
    for (var i = 0; i < n; i++) {
      final t = i / sampleRate;
      final env = 1.0 - (i / n);
      final s = sin(2 * pi * 880 * t) * env;
      pcm[i] = (128 + (s * 100)).clamp(0, 255).toInt();
    }
    final bd = ByteData(44 + pcm.length);
    var o = 0;
    void str(String v) {
      for (final c in v.codeUnits) {
        bd.setUint8(o++, c);
      }
    }

    void u32(int v) {
      bd.setUint32(o, v, Endian.little);
      o += 4;
    }

    void u16(int v) {
      bd.setUint16(o, v, Endian.little);
      o += 2;
    }

    str('RIFF');
    u32(36 + pcm.length);
    str('WAVE');
    str('fmt ');
    u32(16);
    u16(1);
    u16(1);
    u32(sampleRate);
    u32(sampleRate);
    u16(1);
    u16(8);
    str('data');
    u32(pcm.length);
    final out = bd.buffer.asUint8List();
    out.setRange(44, 44 + pcm.length, pcm);
    return out;
  }
}
