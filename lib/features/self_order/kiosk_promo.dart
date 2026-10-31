import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Bundled marketing clip for the self-order header.
///
/// Temporary source (Dishflow banner):
/// https://api.dishflow.code-solution.org/uploads/banners/1792332610203-33019914-8a70-45ff-afc9-7340b67e0c1a.mov
///
/// On disk in the repo: [assetPath] → copied to temp for playback.
abstract final class KioskPromo {
  static const assetPath = 'assets/self_order/promo.mov';
  static const remoteUrl =
      'https://api.dishflow.code-solution.org/uploads/banners/1792332610203-33019914-8a70-45ff-afc9-7340b67e0c1a.mov';

  static String? _cachedFilePath;

  /// Resolves a playable absolute path: staff-picked file, else the bundled asset
  /// copied once into the app temp folder (media_kit needs a real file on Windows).
  static Future<String?> resolvePlayablePath(String? overridePath) async {
    final override = overridePath?.trim();
    if (override != null && override.isNotEmpty) {
      if (File(override).existsSync()) return override;
    }
    return ensureBundledFile();
  }

  static Future<String?> ensureBundledFile() async {
    if (_cachedFilePath != null && File(_cachedFilePath!).existsSync()) {
      return _cachedFilePath;
    }
    try {
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}${Platform.pathSeparator}offlinepos_kiosk_promo.mov');
      if (!await file.exists() || await file.length() < 1000) {
        final data = await rootBundle.load(assetPath);
        await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
      return _cachedFilePath = file.path;
    } catch (_) {
      // Fall back to the source-tree asset during `flutter run` from the repo.
      final dev = File(assetPath);
      if (await dev.exists()) return _cachedFilePath = dev.absolute.path;
      return null;
    }
  }
}
