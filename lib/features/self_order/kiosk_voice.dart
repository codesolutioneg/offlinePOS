import 'dart:async';
import 'dart:io';

/// Spoken English prompts for the self-order kiosk (Windows SAPI; no TTS package).
class KioskVoice {
  KioskVoice._();

  static Future<void>? _queue;

  /// Soft welcome when the phone step is shown.
  static void welcome() => _speak(
        'Welcome. Enter your phone number to start.',
      );

  /// After the guest taps Start ordering.
  static void startNow() => _speak('Start now. Please choose your food.');

  /// After the order is parked for the cashier.
  static void orderConfirmed() => _speak(
        'Your order is confirmed. Please proceed to the cashier with your order number.',
      );

  static void _speak(String text) {
    if (!Platform.isWindows) return;
    _queue = (_queue ?? Future.value()).then((_) => _run(text));
  }

  static Future<void> _run(String text) async {
    final escaped = text.replaceAll("'", "''");
    try {
      await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-WindowStyle',
          'Hidden',
          '-Command',
          "Add-Type -AssemblyName System.Speech; "
              "\$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; "
              "\$s.Rate = -1; "
              "try { \$s.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female) } catch {}; "
              "\$s.Speak('$escaped')",
        ],
        runInShell: false,
      );
    } catch (_) {}
  }
}
