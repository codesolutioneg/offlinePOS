import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/db/schema.dart';
import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/lan/lan_credential.dart';
import '../../core/lan/lan_peer.dart';
import '../../core/lan/lan_wiring.dart';

/// What a device with no fabric has to report: nothing. A real answer rather than a
/// missing one, so the screen reads the same on a one-till shop as on a till whose
/// switch died.
const LanFacts _noFabric = (
  servingAt: null,
  peers: <LanPeer>[],
  refused: <LanPeer>[],
  cursors: <String, int>{},
  lastPassAt: null,
  lastError: null,
);

/// What this device is on the shop LAN, and who else it can see.
///
/// The point of the screen is to answer the two questions a support call actually
/// starts with: is this device sharing state at all, and can it see the other one.
/// Both are facts about right now, so the peer list carries a last-seen age rather
/// than a green dot that means nothing once a switch dies.
class LanSettingsScreen extends StatefulWidget {
  const LanSettingsScreen({
    super.key,
    required this.settings,
    required this.deviceId,
    required this.onChanged,
    this.buildDefault = false,
    this.facts,
    this.onSyncNow,
    this.nowFn = DateTime.now,
  });

  final SettingsStore settings;

  /// This device's id, which is its identity to every peer. Shown in full because
  /// it is what support asks for.
  final String deviceId;

  final VoidCallback onChanged;

  /// What the build was compiled with, which is the answer used until someone sets
  /// the switch on the device.
  final bool buildDefault;

  /// What the fabric knows, read on every build. Null when this device has no
  /// fabric at all, which is the ordinary single-till case.
  final LanFacts Function()? facts;

  /// Runs one catch-up pass now. Null when the fabric is not running.
  final Future<void> Function()? onSyncNow;

  final DateTime Function() nowFn;

  @override
  State<LanSettingsScreen> createState() => _LanSettingsScreenState();
}

class _LanSettingsScreenState extends State<LanSettingsScreen> {
  late final TextEditingController _name =
      TextEditingController(text: widget.settings.lanDeviceName ?? '');
  late final TextEditingController _shopKey =
      TextEditingController(text: widget.settings.lanShopKey ?? '');
  late bool _enabled = widget.settings.lanEnabled(fallback: widget.buildDefault);

  @override
  void dispose() {
    _name.dispose();
    _shopKey.dispose();
    super.dispose();
  }

  void _setEnabled(bool value) {
    widget.settings.setLanEnabled(value);
    // A shop that has never shared gets its key here rather than on the next start,
    // so whoever just flicked the switch can copy it to the other tills without
    // restarting anything.
    if (value && (widget.settings.lanShopKey ?? '').isEmpty) {
      final made = LanCredential.newKey();
      widget.settings.lanShopKey = made;
      _shopKey.text = made;
    }
    widget.onChanged();
    setState(() => _enabled = value);
  }

  void _saveShopKey() {
    final key = _shopKey.text.trim();
    if (key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(
              context, 'A shop key is needed before this device can share.'))));
      return;
    }
    widget.settings.lanShopKey = key;
    widget.onChanged();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(context, 'Saved. Takes effect when this device restarts.'))));
  }

  Future<void> _copyShopKey() async {
    await Clipboard.setData(ClipboardData(text: _shopKey.text.trim()));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr(context, 'Copied'))));
  }

  /// Rotating the key unpairs every other device until it is given the new one, so
  /// this asks first. It is the right move after a key has been handed to someone who
  /// should not have it, and the wrong move by accident on a busy Friday.
  Future<void> _replaceShopKey() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'New key')),
        content: Text(tr(
            context,
            'The other devices stop sharing with this one until they are given '
                'the new key. This device keeps using the old key until it '
                'restarts, so restart it once the others are set.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr(context, 'Cancel')),
          ),
          FilledButton(
            key: const Key('lan-confirm-new-key'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'Replace')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final made = LanCredential.newKey();
    widget.settings.lanShopKey = made;
    widget.onChanged();
    setState(() => _shopKey.text = made);
  }

  void _saveName() {
    widget.settings.lanDeviceName = _name.text;
    widget.onChanged();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr(context, 'Saved'))));
  }

  @override
  Widget build(BuildContext context) {
    final facts = widget.facts?.call() ?? _noFabric;
    final peers = facts.peers;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Shop network'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            key: const Key('lan-enabled'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr(context, 'Share with the other devices')),
            subtitle: Text(tr(
                context,
                'Open tabs, kitchen tickets and the floor plan. Selling never '
                    'waits on this, and the change takes effect when this device '
                    'next starts.')),
            value: _enabled,
            onChanged: _setEnabled,
          ),
          const Divider(height: 24),
          TextField(
            key: const Key('lan-device-name'),
            controller: _name,
            decoration: InputDecoration(
              labelText: tr(context, 'What this device is called'),
              hintText: tr(context, 'Front till'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton(
              key: const Key('lan-save-name'),
              onPressed: _saveName,
              child: Text(tr(context, 'Save')),
            ),
          ),
          const Divider(height: 24),
          Text(tr(context, 'Pairing'),
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            tr(
                context,
                'Every device in the shop shares one key. Copy it from the first '
                    'device into the others. A device with a different key is turned '
                    'away, so nothing else on the network can read the tabs.'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('lan-shop-key'),
            controller: _shopKey,
            decoration: InputDecoration(
              labelText: tr(context, 'Shop key'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                key: const Key('lan-save-key'),
                onPressed: _saveShopKey,
                child: Text(tr(context, 'Save')),
              ),
              OutlinedButton(
                key: const Key('lan-copy-key'),
                onPressed: _copyShopKey,
                child: Text(tr(context, 'Copy')),
              ),
              OutlinedButton(
                key: const Key('lan-new-key'),
                onPressed: _replaceShopKey,
                child: Text(tr(context, 'New key')),
              ),
            ],
          ),
          const Divider(height: 24),
          _fact(tr(context, 'Device id'), widget.deviceId, keyValue: 'lan-device-id'),
          _fact(tr(context, 'Answering on'),
              facts.servingAt ?? tr(context, 'not serving'),
              keyValue: 'lan-serving'),
          _fact(tr(context, 'Data version'), '${Schema.version}'),
          _fact(tr(context, 'Last catch-up'), _ago(facts.lastPassAt),
              keyValue: 'lan-last-pass'),
          if (facts.lastError case final problem?)
            _fact(tr(context, 'Last problem'), problem,
                keyValue: 'lan-last-error'),
          if (widget.onSyncNow != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                key: const Key('lan-sync-now'),
                onPressed: () async {
                  await widget.onSyncNow!();
                  if (mounted) setState(() {});
                },
                icon: const Icon(Icons.sync),
                label: Text(tr(context, 'Catch up now')),
              ),
            ),
          ],
          const Divider(height: 24),
          Text(tr(context, 'Devices on this network'),
              style: Theme.of(context).textTheme.titleMedium),
          if (peers.isEmpty)
            Padding(
              key: const Key('lan-no-peers'),
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(tr(
                  context,
                  'Nothing else found yet. A single-till shop is expected to '
                      'look like this.')),
            ),
          for (final peer in peers)
            ListTile(
              key: Key('lan-peer-${peer.deviceId}'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.point_of_sale),
              title: Text(peer.name),
              subtitle: Text('${peer.host}:${peer.port}  ${peer.deviceId}'),
              trailing: Text([
                _ago(peer.lastSeenAt),
                if (facts.cursors[peer.deviceId] case final seq?)
                  '${tr(context, 'read to')} $seq',
              ].join('\n'), textAlign: TextAlign.end),
            ),
          if (facts.refused.isNotEmpty) ...[
            const Divider(height: 24),
            Text(tr(context, 'Turned away'),
                style: Theme.of(context).textTheme.titleMedium),
            for (final peer in facts.refused)
              ListTile(
                key: Key('lan-refused-${peer.deviceId}'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.block),
                title: Text(peer.name),
                subtitle: Text(
                    '${peer.host}  ${tr(context, 'data version')} ${peer.schemaVersion}'
                    ' / ${Schema.version}'),
              ),
          ],
        ],
      ),
    );
  }

  Widget _fact(String label, String value, {String? keyValue}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 150, child: Text(label)),
            Expanded(
              child: Text(value,
                  key: keyValue == null ? null : Key(keyValue),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );

  /// A plain age, because a timestamp on its own does not answer "is it working
  /// right now". Never means never, not zero seconds ago.
  String _ago(DateTime? at) {
    if (at == null) return tr(context, 'never');
    final seconds = widget.nowFn().toUtc().difference(at.toUtc()).inSeconds;
    if (seconds < 60) return '${seconds < 0 ? 0 : seconds}s';
    final minutes = seconds ~/ 60;
    if (minutes < 60) return '${minutes}m';
    return '${minutes ~/ 60}h ${minutes % 60}m';
  }
}
