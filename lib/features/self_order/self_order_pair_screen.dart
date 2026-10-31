import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';

/// First-run pairing for the dedicated self-order binary: paste the shop key
/// from the primary's Shop network screen (no join PIN).
class SelfOrderPairScreen extends StatefulWidget {
  const SelfOrderPairScreen({
    super.key,
    required this.onPair,
    this.initialHost = '127.0.0.1',
    this.initialPort = 45333,
  });

  /// Returns null on success, or an error message.
  final Future<String?> Function(String host, int port, String shopKey) onPair;
  final String initialHost;
  final int initialPort;

  @override
  State<SelfOrderPairScreen> createState() => _SelfOrderPairScreenState();
}

class _SelfOrderPairScreenState extends State<SelfOrderPairScreen> {
  late final TextEditingController _host =
      TextEditingController(text: widget.initialHost);
  late final TextEditingController _port =
      TextEditingController(text: '${widget.initialPort}');
  final _key = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 0;
    final key = _key.text.trim();
    if (host.isEmpty || port <= 0 || key.isEmpty) {
      setState(() => _error = tr(context, 'Enter host, port and shop key'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.onPair(host, port, key);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.all(32),
              children: [
                const Icon(Icons.touch_app, size: 48, color: AppColors.primary),
                const SizedBox(height: 16),
                Text(tr(context, 'Self-order kiosk'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 28, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text(
                  tr(
                      context,
                      'No PIN. On the primary till open Shop network, copy the '
                          'Shop key, paste it here, and connect.'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppColors.textMutedLight, height: 1.4),
                ),
                const SizedBox(height: 28),
                TextField(
                  key: const Key('kiosk-pair-host'),
                  controller: _host,
                  decoration: InputDecoration(
                    labelText: tr(context, 'Primary host'),
                    border: const OutlineInputBorder(),
                    helperText: tr(context,
                        'Same PC as primary: 127.0.0.1 — other PC: Wi‑Fi IP'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('kiosk-pair-port'),
                  controller: _port,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: tr(context, 'Port'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('kiosk-pair-key'),
                  controller: _key,
                  decoration: InputDecoration(
                    labelText: tr(context, 'Shop key'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: const TextStyle(color: AppColors.error)),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  height: 52,
                  child: FilledButton(
                    key: const Key('kiosk-pair-connect'),
                    onPressed: _busy ? null : _connect,
                    child: _busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(tr(context, 'Connect to primary'),
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
