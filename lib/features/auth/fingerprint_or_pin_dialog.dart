import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/fingerprint_diagnostics.dart';
import '../../core/auth/fingerprint_service.dart';
import '../../core/i18n/l10n.dart';
import '../../core/widgets/numeric_keypad.dart';

/// Result of a fingerprint-or-PIN gate.
class FingerprintOrPinResult {
  const FingerprintOrPinResult.pin(this.pin, {this.totpCode})
      : matchedUserId = null;
  const FingerprintOrPinResult.fingerprint(this.matchedUserId)
      : pin = null,
        totpCode = null;

  final String? pin;
  final String? totpCode;
  final String? matchedUserId;

  bool get isFingerprint => matchedUserId != null;
}

/// Shows fingerprint capture when the ZK reader is ready; always offers PIN.
///
/// While open, the dialog listens continuously — place a finger, no button.
Future<FingerprintOrPinResult?> showFingerprintOrPin(
  BuildContext context, {
  required FingerprintService fingerprints,
  required String title,
  required String message,
  bool askTotp = false,
  Future<void> Function()? prepareTemplates,
}) {
  return showDialog<FingerprintOrPinResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _FingerprintOrPinDialog(
      fingerprints: fingerprints,
      title: title,
      message: message,
      askTotp: askTotp,
      prepareTemplates: prepareTemplates,
    ),
  );
}

class _FingerprintOrPinDialog extends StatefulWidget {
  const _FingerprintOrPinDialog({
    required this.fingerprints,
    required this.title,
    required this.message,
    required this.askTotp,
    this.prepareTemplates,
  });

  final FingerprintService fingerprints;
  final String title;
  final String message;
  final bool askTotp;
  final Future<void> Function()? prepareTemplates;

  @override
  State<_FingerprintOrPinDialog> createState() =>
      _FingerprintOrPinDialogState();
}

class _FingerprintOrPinDialogState extends State<_FingerprintOrPinDialog> {
  bool _readerReady = false;
  bool _checking = true;
  bool _usePin = false;
  bool _listening = false;
  String? _hint;
  String _pin = '';
  String _totp = '';
  int _listenGen = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  @override
  void dispose() {
    _listenGen++; // cancel in-flight listen loop
    unawaited(widget.fingerprints.clearPending());
    super.dispose();
  }

  Future<void> _probe() async {
    final prep = widget.prepareTemplates;
    if (prep != null) {
      try {
        await prep();
      } catch (_) {}
    }
    final diag = await FingerprintDiagnostics().probe();
    final ok = diag.ok && await widget.fingerprints.warmUp(force: true);
    if (!mounted) return;
    setState(() {
      _readerReady = ok;
      _checking = false;
      _usePin = !ok;
      if (!ok) {
        _hint = [
          diag.summary,
          if (widget.fingerprints.lastError != null)
            widget.fingerprints.lastError!,
          if (diag.logPath != null) 'Log: ${diag.logPath}',
        ].where((s) => s.trim().isNotEmpty).join('\n');
      }
    });
    if (ok) unawaited(_listenLoop());
  }

  Future<void> _listenLoop() async {
    final gen = ++_listenGen;
    if (_listening || _usePin) return;
    setState(() {
      _listening = true;
      _hint = null;
    });

    while (mounted && gen == _listenGen && !_usePin && _readerReady) {
      if (mounted) {
        setState(() {
          _hint ??= tr(context, 'Place your finger on the reader…');
        });
      }

      final outcome = await widget.fingerprints.identifyOnce(
        timeout: const Duration(seconds: 12),
      );
      if (!mounted || gen != _listenGen || _usePin) break;

      switch (outcome) {
        case FingerprintIdentifyMatch(:final userId):
          Navigator.pop(context, FingerprintOrPinResult.fingerprint(userId));
          return;
        case FingerprintIdentifyNoMatch():
          setState(() {
            _hint = tr(context, 'No match — keep finger on reader or use PIN');
          });
          await Future<void>.delayed(const Duration(milliseconds: 400));
        case FingerprintIdentifyEmptyBank():
          setState(() {
            _hint = tr(context, 'No fingerprints enrolled — use PIN');
          });
          await Future<void>.delayed(const Duration(milliseconds: 800));
        case FingerprintIdentifyTimeout():
        case FingerprintIdentifyUnavailable():
          // Keep listening silently — user has not placed a finger yet.
          if (mounted && gen == _listenGen) {
            setState(() {
              _hint = tr(context, 'Place your finger on the reader…');
            });
          }
      }
    }

    if (mounted && gen == _listenGen) {
      setState(() => _listening = false);
    }
  }

  void _switchToPin() {
    _listenGen++;
    setState(() {
      _usePin = true;
      _listening = false;
      _hint = null;
    });
    unawaited(widget.fingerprints.clearPending());
  }

  void _switchToFingerprint() {
    setState(() => _usePin = false);
    unawaited(_listenLoop());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.message),
            const SizedBox(height: 12),
            if (_checking)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (!_usePin && _readerReady) ...[
              Icon(Icons.fingerprint,
                  size: 64, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 8),
              if (_listening)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
              Text(
                _hint ?? tr(context, 'Place your finger on the reader…'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _switchToPin,
                child: Text(tr(context, 'Use PIN instead')),
              ),
            ] else ...[
              if (_readerReady)
                TextButton(
                  onPressed: _switchToFingerprint,
                  child: Text(tr(context, 'Use fingerprint')),
                ),
              NumericKeypad(
                decimal: false,
                compact: true,
                onKey: (d) {
                  if (_pin.length >= 6) return;
                  setState(() => _pin += d);
                },
                onBackspace: () => setState(() {
                  if (_pin.isNotEmpty) {
                    _pin = _pin.substring(0, _pin.length - 1);
                  }
                }),
                onClear: () => setState(() => _pin = ''),
              ),
              Text(
                _pin.isEmpty ? '• • • •' : '•' * _pin.length,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              if (widget.askTotp) ...[
                const SizedBox(height: 8),
                TextField(
                  decoration: InputDecoration(
                    labelText: tr(context, 'Authenticator code'),
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (v) => _totp = v,
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            _listenGen++;
            Navigator.pop(context);
          },
          child: Text(tr(context, 'Cancel')),
        ),
        if (_usePin || !_readerReady)
          FilledButton(
            onPressed: _pin.length >= 4
                ? () => Navigator.pop(
                      context,
                      FingerprintOrPinResult.pin(
                        _pin,
                        totpCode: widget.askTotp ? _totp : null,
                      ),
                    )
                : null,
            child: Text(tr(context, 'OK')),
          ),
      ],
    );
  }
}
