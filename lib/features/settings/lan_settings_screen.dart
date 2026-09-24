import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/db/schema.dart';
import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/lan/lan_cart_board.dart';
import '../../core/lan/lan_credential.dart';
import '../../core/lan/lan_peer.dart';
import '../../core/lan/lan_shift_board.dart';
import '../../core/lan/lan_wiring.dart';
import '../../domain/table_section_config.dart';

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
    this.onJoinPrimary,
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

  /// Secondary presents a PIN to [peer] (the primary). Returns an error message
  /// or null on success. [onProgress] reports first-join sync steps (0..1).
  final Future<String?> Function(
    LanPeer peer,
    String pin, {
    void Function(String step, double progress)? onProgress,
  })? onJoinPrimary;

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
  late bool _allowTakeover = widget.settings.lanAllowTakeover;
  late LanDayClosePolicy _dayClose = LanShiftBoard(widget.settings).policy;
  late bool _displayCart = LanCartBoard(widget.settings).publishing;

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
        content: Text(tr(context, 'Saved. This device is paired on it now.'))));
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
                'the new key. This device starts using it straight away, so set '
                'the others now.')),
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

  void _setRole(DeviceRole role) {
    widget.settings.deviceRole = role;
    if (role == DeviceRole.primary) {
      if (!(widget.settings.lanEnabled(fallback: widget.buildDefault))) {
        _setEnabled(true);
      }
      if ((widget.settings.lanShopKey ?? '').isEmpty) {
        final made = LanCredential.newKey();
        widget.settings.lanShopKey = made;
        _shopKey.text = made;
      }
      widget.settings.lanRolePromptDismissed = true;
    } else if (role == DeviceRole.secondary) {
      widget.settings.lanRolePromptDismissed = true;
    }
    widget.onChanged();
    setState(() {});
  }

  Future<void> _clearPairing() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('lan-unlink-confirm'),
        title: Text(tr(ctx, 'Unlink this till?')),
        content: Text(tr(
            ctx,
            'Clears the shop key and Primary/Secondary role so you can join '
                'again with a new PIN, or become the primary. Menu and staff '
                'stay until the next join replaces them.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr(ctx, 'Cancel')),
          ),
          FilledButton(
            key: const Key('lan-unlink-confirm-yes'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr(ctx, 'Unlink')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    widget.settings.clearLanPairing();
    // Drop any key that was only sitting in the text field — settings no longer
    // hold one, and Share must not invent a replacement until Primary / Join.
    _shopKey.text = '';
    widget.onChanged();
    setState(() {
      _shopKey.text = widget.settings.lanShopKey ?? '';
    });
    if (!mounted) return;
    final stillHeld = (widget.settings.lanShopKey ?? '').isNotEmpty ||
        widget.settings.deviceRole != DeviceRole.unset;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(stillHeld
          ? tr(context, 'Could not clear pairing. Try again.')
          : tr(
              context,
              'Unlinked. Pick Primary, or Secondary and Join with a new PIN. '
                  'Restart if Share was already on.')),
    ));
  }

  Future<void> _issueJoinPin() async {
    final pin = widget.settings.issueJoinPin();
    if (pin == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(context, 'Only the primary till can mint join PINs.'))));
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Join PIN')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr(ctx,
                'Give this one-time code to the secondary till. It expires in 12 hours.')),
            const SizedBox(height: 16),
            SelectableText(
              pin,
              key: const Key('lan-issued-pin'),
              style: Theme.of(ctx).textTheme.headlineMedium,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: pin));
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: Text(tr(ctx, 'Copy')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr(ctx, 'Done')),
          ),
        ],
      ),
    );
    setState(() {});
  }

  Future<void> _joinSelected(LanPeer peer) async {
    final join = widget.onJoinPrimary;
    if (join == null) return;
    final ctrl = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Join primary')),
        content: TextField(
          key: const Key('lan-join-pin-field'),
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            labelText: tr(ctx, 'Join PIN'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
            key: const Key('lan-join-confirm'),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr(ctx, 'Join')),
          ),
        ],
      ),
    );
    if (pin == null || pin.isEmpty || !mounted) return;

    // StatefulBuilder owns progress UI — no ValueNotifier dispose/removeListener
    // race (that race shows as "Null check operator used on a null value").
    var cancelled = false;
    var dialogAlive = true;
    var stepLabel = tr(context, 'Connecting to primary...');
    var fraction = 0.02;
    void Function(void Function())? setProgress;

    final dialogClosed = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (ctx, setLocal) {
            setProgress = setLocal;
            return AlertDialog(
              key: const Key('lan-join-progress'),
              title: Text(tr(ctx, 'Syncing from primary')),
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(stepLabel, key: const Key('lan-join-progress-step')),
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value:
                          fraction <= 0 ? null : fraction.clamp(0.0, 1.0),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      fraction <= 0
                          ? tr(ctx, 'Working...')
                          : '${(fraction * 100).clamp(0, 100).round()}%',
                      textAlign: TextAlign.end,
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  key: const Key('lan-join-progress-cancel'),
                  onPressed: () {
                    cancelled = true;
                    Navigator.of(ctx).pop();
                  },
                  child: Text(tr(ctx, 'Cancel')),
                ),
              ],
            );
          },
        ),
      ),
    ).whenComplete(() => dialogAlive = false);
    await Future<void>.delayed(Duration.zero);
    if (!mounted || cancelled) {
      if (mounted && !cancelled) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      await dialogClosed;
      return;
    }

    String? err;
    try {
      err = await join(
        peer,
        pin,
            onProgress: (label, nextFraction) {
          if (cancelled || !dialogAlive) return;
          try {
            setProgress?.call(() {
              stepLabel = label;
              fraction = nextFraction;
            });
          } catch (_) {}
        },
      );
    } catch (e) {
      err = e.toString();
    }
    if (mounted && !cancelled) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    await dialogClosed;
    if (!mounted || cancelled) return;
    final unreachable = err != null &&
        (err.contains('TimeoutException') ||
            err.contains('SocketException') ||
            err.contains('Connection timed out') ||
            err.contains('Failed host lookup'));
    // First line only — runStep prefixes the failing stage; stack stays in logs.
    final errLine = err?.split('\n').first.trim();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(err == null
          ? tr(context, 'Joined. This till now shares the primary shop key.')
          : unreachable
              ? tr(
                  context,
                  'Could not reach the primary. Check both devices are on '
                      'the same Wi‑Fi, Share is On, and try Join again.',
                )
              : (errLine ?? err)),
      duration: Duration(seconds: err == null ? 4 : 10),
    ));
    if (err == null) {
      setState(() => _shopKey.text = widget.settings.lanShopKey ?? '');
    }
  }

  @override
  Widget build(BuildContext context) {
    final facts = widget.facts?.call() ?? _noFabric;
    final peers = facts.peers;
    final role = widget.settings.deviceRole;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Shop network'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(tr(context, 'This till\'s role'),
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            tr(
                context,
                'Primary owns join PINs and section settings. Secondary joins '
                    'with a PIN from the primary.'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SegmentedButton<DeviceRole>(
            key: const Key('lan-device-role'),
            segments: [
              ButtonSegment(
                  value: DeviceRole.primary,
                  label: Text(tr(context, 'Primary'))),
              ButtonSegment(
                  value: DeviceRole.secondary,
                  label: Text(tr(context, 'Secondary'))),
            ],
            emptySelectionAllowed: true,
            selected: {
              if (role == DeviceRole.primary || role == DeviceRole.secondary)
                role,
            },
            onSelectionChanged: (s) {
              if (s.isEmpty) {
                _setRole(DeviceRole.unset);
              } else {
                _setRole(s.first);
              }
            },
          ),
          if (role == DeviceRole.primary) ...[
            const SizedBox(height: 12),
            _fact(tr(context, 'Primary device id'), widget.deviceId,
                keyValue: 'lan-primary-id'),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.icon(
                key: const Key('lan-issue-join-pin'),
                onPressed: _issueJoinPin,
                icon: const Icon(Icons.pin),
                label: Text(tr(context, 'Generate join PIN')),
              ),
            ),
            Text(
              '${tr(context, 'Unused join PINs')}: ${widget.settings.joinPinBankCount}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (role == DeviceRole.secondary &&
              widget.onJoinPrimary != null &&
              peers.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(tr(context, 'Join a primary on this network'),
                style: Theme.of(context).textTheme.titleSmall),
            for (final peer in peers)
              ListTile(
                key: Key('lan-join-peer-${peer.deviceId}'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.link),
                title: Text(peer.name),
                subtitle: Text(peer.deviceId),
                trailing: OutlinedButton(
                  onPressed: () => _joinSelected(peer),
                  child: Text(tr(context, 'Join')),
                ),
              ),
          ],
          if (role == DeviceRole.secondary &&
              widget.onJoinPrimary != null &&
              peers.isEmpty) ...[
            const SizedBox(height: 12),
            Text(
              tr(
                  context,
                  'Waiting for the primary on this Wi‑Fi… Keep Share On on both '
                      'devices, then Join when it appears.'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (role == DeviceRole.primary || role == DeviceRole.secondary) ...[
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                key: const Key('lan-unlink'),
                onPressed: _clearPairing,
                icon: const Icon(Icons.link_off),
                label: Text(tr(context, 'Unlink / join again')),
              ),
            ),
          ],
          const Divider(height: 24),
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
          SwitchListTile(
            key: const Key('lan-allow-takeover'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr(context, 'Let another device take over a tab')),
            subtitle: Text(tr(
                context,
                'Off, a tab is settled on the till it was opened on. On, a manager '
                    'on another device can take it, and this one gives it up as it '
                    'agrees, so it is never open in two places.')),
            value: _allowTakeover,
            onChanged: (v) {
              widget.settings.lanAllowTakeover = v;
              widget.onChanged();
              setState(() => _allowTakeover = v);
            },
          ),
          SwitchListTile(
            key: const Key('lan-display-cart'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr(context, 'Show this counter on a customer display')),
            subtitle: Text(tr(
                context,
                'Sends what is being rung to a display device in the shop. Off '
                    'unless there is one: it is the only thing shared while an '
                    'order is on the counter.')),
            value: _displayCart,
            onChanged: (v) {
              LanCartBoard(widget.settings).publishing = v;
              widget.onChanged();
              setState(() => _displayCart = v);
            },
          ),
          ListTile(
            key: const Key('lan-day-close-policy'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr(context, 'When another till closes the day')),
            subtitle: Text(tr(
                context,
                'A device that hears nothing sells exactly as it always did, so '
                    'this never stops the shop when the network is down.')),
            trailing: DropdownButton<LanDayClosePolicy>(
              value: _dayClose,
              onChanged: (p) {
                if (p == null) return;
                LanShiftBoard(widget.settings).policy = p;
                widget.onChanged();
                setState(() => _dayClose = p);
              },
              items: [
                DropdownMenuItem(
                  value: LanDayClosePolicy.off,
                  child: Text(tr(context, 'Say nothing')),
                ),
                DropdownMenuItem(
                  value: LanDayClosePolicy.warn,
                  child: Text(tr(context, 'Warn the others')),
                ),
                DropdownMenuItem(
                  value: LanDayClosePolicy.block,
                  child: Text(tr(context, 'Hold new orders')),
                ),
              ],
            ),
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
          const SizedBox(height: 24),
          Text(
            'LAN build 2026-09-08f',
            key: const Key('lan-build-stamp'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
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
