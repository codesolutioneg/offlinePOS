import 'dart:io';

import 'package:flutter/services.dart';

/// Windows window controls the till is allowed to use.
///
/// Closing the process is not one of them. Minimize leaves the till running
/// and the taskbar brings it back.
class TillWindow {
  static const _channel = MethodChannel('offline_pos/window');

  static Future<void> minimize() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('minimize');
    } catch (_) {}
  }
}
