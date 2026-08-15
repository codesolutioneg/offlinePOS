import 'package:flutter/material.dart';

import '../../core/db/delivery_store.dart';
import '../../core/i18n/l10n.dart';
import '../../domain/catalogue.dart';
import '../../domain/delivery.dart';

/// The three lists a delivery shop maintains: zones with the charge for driving
/// there, the channels orders arrive through, and the drivers who carry them.
///
/// One screen because they are one job, done once when the shop is set up and
/// touched rarely after. Everything written here is local, so it is editable and
/// usable with the line down.
class DeliverySettingsScreen extends StatefulWidget {
  const DeliverySettingsScreen({
    super.key,
    required this.delivery,
    required this.onChanged,
    this.partners = const [],
  });

  final DeliveryStore delivery;

  /// Called after every edit so the caller can refresh anything holding these
  /// lists (the delivery dialog reads them fresh on each open).
  final VoidCallback onChanged;

  /// The partners the catalogue pulled, offered when a channel is invoiced to a
  /// company. Empty simply leaves a channel as a label.
  final List<Customer> partners;

  @override
  State<DeliverySettingsScreen> createState() => _DeliverySettingsScreenState();
}

class _DeliverySettingsScreenState extends State<DeliverySettingsScreen> {
  late List<DeliveryZone> _zones = widget.delivery.zones();
  late List<DeliveryChannel> _channels = widget.delivery.channels();
  late List<Driver> _drivers = widget.delivery.drivers();

  void _reload() {
    setState(() {
      _zones = widget.delivery.zones();
      _channels = widget.delivery.channels();
      _drivers = widget.delivery.drivers();
    });
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 3,
        child: Scaffold(
          appBar: AppBar(
            title: Text(tr(context, 'Delivery')),
            bottom: TabBar(tabs: [
              Tab(key: const Key('tab-zones'), text: tr(context, 'Zones')),
              Tab(key: const Key('tab-channels'), text: tr(context, 'Channels')),
              Tab(key: const Key('tab-drivers'), text: tr(context, 'Drivers')),
            ]),
          ),
          body: TabBarView(children: [_zonesTab(), _channelsTab(), _driversTab()]),
        ),
      );

  // ── zones ────────────────────────────────────────────────────────

  Widget _zonesTab() => ListView(padding: const EdgeInsets.all(12), children: [
        Text(tr(context, 'A zone fills in the delivery charge. The cashier can still change it.'),
            style: const TextStyle(color: Colors.black54)),
        const SizedBox(height: 8),
        if (_zones.isEmpty)
          ListTile(
              key: const Key('no-zones'), title: Text(tr(context, 'No zones yet'))),
        for (final z in _zones)
          ListTile(
            key: Key('zone-${z.id}'),
            title: Text(z.name),
            subtitle: Text(z.fee.toStringAsFixed(2)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                key: Key('edit-zone-${z.id}'),
                icon: const Icon(Icons.edit_outlined),
                tooltip: tr(context, 'Edit'),
                onPressed: () => _zoneDialog(zone: z),
              ),
              IconButton(
                key: Key('delete-zone-${z.id}'),
                icon: const Icon(Icons.delete_outline),
                tooltip: tr(context, 'Remove'),
                onPressed: () {
                  widget.delivery.removeZone(z.id);
                  _reload();
                },
              ),
            ]),
          ),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('add-zone'),
          icon: const Icon(Icons.add),
          label: Text(tr(context, 'Add zone')),
          onPressed: () => _zoneDialog(),
        ),
      ]);

  Future<void> _zoneDialog({DeliveryZone? zone}) async {
    final name = TextEditingController(text: zone?.name ?? '');
    final fee = TextEditingController(
        text: zone == null ? '' : zone.fee.toStringAsFixed(2));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, zone == null ? 'Add zone' : 'Edit zone')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              key: const Key('zone-name'),
              controller: name,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: tr(ctx, 'Zone name'),
                  border: const OutlineInputBorder(),
                  isDense: true)),
          const SizedBox(height: 8),
          TextField(
              key: const Key('zone-fee'),
              controller: fee,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: tr(ctx, 'Delivery charge'),
                  border: const OutlineInputBorder(),
                  isDense: true)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
              key: const Key('save-zone'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr(ctx, 'Save'))),
        ],
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    final amount = double.tryParse(fee.text.trim()) ?? 0;
    if (zone == null) {
      widget.delivery.addZone(name: name.text, fee: amount);
    } else {
      widget.delivery.updateZone(zone.id, name: name.text, fee: amount);
    }
    _reload();
  }

  // ── channels ─────────────────────────────────────────────────────

  Widget _channelsTab() => ListView(padding: const EdgeInsets.all(12), children: [
        Text(
            tr(context,
                'Where the order came from. A channel invoiced to a company books against that customer.'),
            style: const TextStyle(color: Colors.black54)),
        const SizedBox(height: 8),
        if (_channels.isEmpty)
          ListTile(
              key: const Key('no-channels'),
              title: Text(tr(context, 'No channels yet'))),
        for (final c in _channels)
          ListTile(
            key: Key('channel-${c.id}'),
            title: Text(c.name),
            subtitle: Text(c.partnerId == null
                ? tr(context, 'No company customer')
                : _partnerName(c.partnerId!)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                key: Key('edit-channel-${c.id}'),
                icon: const Icon(Icons.edit_outlined),
                tooltip: tr(context, 'Edit'),
                onPressed: () => _channelDialog(channel: c),
              ),
              IconButton(
                key: Key('delete-channel-${c.id}'),
                icon: const Icon(Icons.delete_outline),
                tooltip: tr(context, 'Remove'),
                onPressed: () {
                  widget.delivery.removeChannel(c.id);
                  _reload();
                },
              ),
            ]),
          ),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('add-channel'),
          icon: const Icon(Icons.add),
          label: Text(tr(context, 'Add channel')),
          onPressed: () => _channelDialog(),
        ),
      ]);

  String _partnerName(int id) => widget.partners
      .where((p) => p.id == id)
      .map((p) => p.name)
      .firstOrNull ??
      '$id';

  Future<void> _channelDialog({DeliveryChannel? channel}) async {
    final name = TextEditingController(text: channel?.name ?? '');
    var partnerId = channel?.partnerId;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(tr(ctx, channel == null ? 'Add channel' : 'Edit channel')),
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  key: const Key('channel-name'),
                  controller: name,
                  autofocus: true,
                  decoration: InputDecoration(
                      labelText: tr(ctx, 'Channel name'),
                      border: const OutlineInputBorder(),
                      isDense: true)),
              if (widget.partners.isNotEmpty) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<int?>(
                  key: const Key('channel-partner'),
                  initialValue: partnerId,
                  isExpanded: true,
                  decoration: InputDecoration(
                      labelText: tr(ctx, 'Company customer'),
                      border: const OutlineInputBorder(),
                      isDense: true),
                  items: [
                    DropdownMenuItem<int?>(
                        value: null,
                        child: Text(tr(ctx, 'No company customer'))),
                    for (final p in widget.partners)
                      DropdownMenuItem<int?>(value: p.id, child: Text(p.name)),
                  ],
                  onChanged: (v) => setSt(() => partnerId = v),
                ),
              ],
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr(ctx, 'Cancel'))),
            FilledButton(
                key: const Key('save-channel'),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr(ctx, 'Save'))),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    if (channel == null) {
      widget.delivery.addChannel(name: name.text, partnerId: partnerId);
    } else {
      widget.delivery
          .updateChannel(channel.id, name: name.text, partnerId: partnerId);
    }
    _reload();
  }

  // ── drivers ──────────────────────────────────────────────────────

  Widget _driversTab() => ListView(padding: const EdgeInsets.all(12), children: [
        Text(
            tr(context,
                'Who takes the order out. A driver who leaves is switched off and keeps their old orders.'),
            style: const TextStyle(color: Colors.black54)),
        const SizedBox(height: 8),
        if (_drivers.isEmpty)
          ListTile(
              key: const Key('no-drivers-configured'),
              title: Text(tr(context, 'No drivers yet'))),
        for (final d in _drivers)
          SwitchListTile(
            key: Key('driver-${d.id}'),
            value: d.active,
            title: Text(d.name),
            subtitle: Text(d.phone ?? tr(context, 'No phone')),
            secondary: IconButton(
              key: Key('edit-driver-${d.id}'),
              icon: const Icon(Icons.edit_outlined),
              tooltip: tr(context, 'Edit'),
              onPressed: () => _driverDialog(driver: d),
            ),
            onChanged: (on) {
              widget.delivery.setDriverActive(d.id, on);
              _reload();
            },
          ),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('add-driver'),
          icon: const Icon(Icons.add),
          label: Text(tr(context, 'Add driver')),
          onPressed: () => _driverDialog(),
        ),
      ]);

  Future<void> _driverDialog({Driver? driver}) async {
    final name = TextEditingController(text: driver?.name ?? '');
    final phone = TextEditingController(text: driver?.phone ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, driver == null ? 'Add driver' : 'Edit driver')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              key: const Key('driver-name'),
              controller: name,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: tr(ctx, 'Name'),
                  border: const OutlineInputBorder(),
                  isDense: true)),
          const SizedBox(height: 8),
          TextField(
              key: const Key('driver-phone'),
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                  labelText: tr(ctx, 'Phone'),
                  border: const OutlineInputBorder(),
                  isDense: true)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
              key: const Key('save-driver'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr(ctx, 'Save'))),
        ],
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    if (driver == null) {
      widget.delivery.addDriver(name: name.text, phone: phone.text);
    } else {
      widget.delivery.updateDriver(driver.id,
          name: name.text, phone: phone.text, active: driver.active);
    }
    _reload();
  }
}
