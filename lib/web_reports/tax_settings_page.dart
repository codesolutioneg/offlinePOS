import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/i18n/l10n.dart';
import '../core/theme/app_colors.dart';
import 'site_api.dart';
import 'site_widgets.dart';

/// Owner-only ETA link settings — same shape as Dishflow `eta_integration`.
/// Open from a branch to bind that branch's Dishflow connection + POS creds.
class TaxSettingsPage extends StatefulWidget {
  const TaxSettingsPage({
    super.key,
    required this.api,
    this.branchId,
    this.branchName,
    this.initialConnectionId,
  });

  final SiteApi api;
  final String? branchId;
  final String? branchName;
  final String? initialConnectionId;

  @override
  State<TaxSettingsPage> createState() => _TaxSettingsPageState();
}

class _TaxSettingsPageState extends State<TaxSettingsPage> {
  var _loading = true;
  var _saving = false;
  var _syncing = false;
  Object? _error;

  final _rin = TextEditingController();
  final _trade = TextEditingController();
  final _activity = TextEditingController(text: '5610');
  final _connectionId = TextEditingController();
  var _useSandbox = false;
  var _connectionName = '';
  List<_IntegrationDraft> _integrations = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _rin.dispose();
    _trade.dispose();
    _activity.dispose();
    _connectionId.dispose();
    for (final i in _integrations) {
      i.dispose();
    }
    super.dispose();
  }

  String get _nasrHintId => 'yFsBtvlradoAkKSascZ3';

  bool _looksLikeNasr(String name) {
    final n = name.toLowerCase();
    return n.contains('nasr') ||
        n.contains('naser') ||
        n.contains('balkan') ||
        name.contains('نصر') ||
        name.contains('بالكنز');
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await widget.api.taxSettings();
      _apply(s);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _apply(SiteTaxSettings s) {
    for (final i in _integrations) {
      i.dispose();
    }
    _rin.text = s.rin;
    _trade.text = s.companyTradeName;
    _activity.text = s.activityCode.isEmpty ? '5610' : s.activityCode;
    final preferred = (widget.initialConnectionId ?? '').trim().isNotEmpty
        ? widget.initialConnectionId!.trim()
        : (widget.branchName != null && _looksLikeNasr(widget.branchName!)
            ? _nasrHintId
            : (s.connectionId.isEmpty ? _nasrHintId : s.connectionId));
    _connectionId.text = preferred;
    _connectionName = preferred == _nasrHintId
        ? tr(context, 'Balkans Nasr City')
        : (s.connectionName.isEmpty
            ? (widget.branchName ?? preferred)
            : s.connectionName);
    _useSandbox = s.useSandbox;
    _integrations = [
      for (final i in s.integrations) _IntegrationDraft.fromModel(i),
    ];
    setState(() {});
  }

  Future<void> _syncFromFirebase() async {
    setState(() => _syncing = true);
    try {
      final s = await widget.api.taxSettingsSync();
      if (!mounted) return;
      _apply(s);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'Synced tax settings from Firebase'))),
      );
    } catch (e) {
      if (mounted) showSiteError(context, e);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final conn = _connectionId.text.trim();
      final s = await widget.api.taxSettingsSave(
        connectionId: conn,
        rin: _rin.text.trim(),
        companyTradeName: _trade.text.trim(),
        activityCode: _activity.text.trim().isEmpty ? '5610' : _activity.text.trim(),
        useSandbox: _useSandbox,
        integrations: [for (final d in _integrations) d.toModel()],
      );
      final branchId = widget.branchId;
      if (branchId != null && branchId.isNotEmpty) {
        await widget.api.setBranchTaxConnection(branchId, conn);
      }
      if (!mounted) return;
      _apply(s);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'Tax settings saved'))),
      );
    } catch (e) {
      if (mounted) showSiteError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _addIntegration() {
    setState(() {
      _integrations.add(
        _IntegrationDraft(
          id: 'new_${DateTime.now().microsecondsSinceEpoch}',
          name: tr(context, 'New integration'),
          isDefault: _integrations.isEmpty,
        ),
      );
    });
  }

  void _removeIntegration(int index) {
    setState(() {
      final gone = _integrations.removeAt(index);
      gone.dispose();
      if (_integrations.isNotEmpty &&
          !_integrations.any((i) => i.isDefault)) {
        _integrations.first.isDefault = true;
      }
    });
  }

  void _setDefault(int index) {
    setState(() {
      for (var i = 0; i < _integrations.length; i++) {
        _integrations[i].isDefault = i == index;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: AppColors.brandNavy,
        leading: IconButton(
          tooltip: tr(context, 'Back'),
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: Text(
          widget.branchName?.trim().isNotEmpty == true
              ? '${tr(context, 'Tax link')} — ${widget.branchName}'
              : tr(context, 'Tax link settings'),
          style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.2),
        ),
        actions: [
          IconButton(
            tooltip: tr(context, 'Refresh'),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF8FAFC), Color(0xFFEEF2F7)],
          ),
        ),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('$_error', textAlign: TextAlign.center),
                    ),
                  )
                : Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 48),
                        children: [
                          Text(
                            widget.branchName?.trim().isNotEmpty == true
                                ? tr(context,
                                    'Tax link for this branch — same ETA shape as Dishflow. Save binds the Dishflow connection to the branch.')
                                : tr(context,
                                    'Same ETA link as Dishflow. Balkans Nasr City is already loaded — edit or add POS credentials here.'),
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: AppColors.textSecondaryLight,
                                  height: 1.45,
                                ),
                          ),
                          const SizedBox(height: 16),
                          if (widget.branchName?.trim().isNotEmpty == true)
                            _section(
                              tr(context, 'Reports branch'),
                              children: [
                                Text(
                                  widget.branchName!,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                    color: AppColors.brandNavy,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  tr(context,
                                      'Pairing branch on this site. Link it to a Dishflow connection below.'),
                                  style: const TextStyle(
                                    color: AppColors.textMutedLight,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          _section(
                            tr(context, 'Dishflow connection'),
                            children: [
                              _labeledField(
                                tr(context, 'Connection ID'),
                                TextField(
                                  controller: _connectionId,
                                  decoration: _inputDeco(
                                    hint: _nasrHintId,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _connectionName,
                                style: const TextStyle(
                                  color: AppColors.textMutedLight,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          _section(
                            tr(context, 'Company'),
                            children: [
                              _labeledField(
                                tr(context, 'Tax ID (RIN)'),
                                TextField(
                                  controller: _rin,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                  ],
                                  decoration: _inputDeco(),
                                ),
                              ),
                              const SizedBox(height: 12),
                              _labeledField(
                                tr(context, 'Company trade name'),
                                TextField(
                                  controller: _trade,
                                  decoration: _inputDeco(),
                                ),
                              ),
                              const SizedBox(height: 12),
                              _labeledField(
                                tr(context, 'Activity code'),
                                TextField(
                                  controller: _activity,
                                  decoration: _inputDeco(hint: '5610'),
                                ),
                              ),
                              const SizedBox(height: 8),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  tr(context, 'Sandbox (testing)'),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.brandNavy,
                                  ),
                                ),
                                subtitle: Text(
                                  tr(context, 'Off = production ETA'),
                                  style: const TextStyle(
                                    color: AppColors.textMutedLight,
                                  ),
                                ),
                                value: _useSandbox,
                                activeColor: AppColors.primary,
                                onChanged: (v) => setState(() => _useSandbox = v),
                              ),
                            ],
                          ),
                          _section(
                            tr(context, 'POS integrations'),
                            trailing: TextButton.icon(
                              onPressed: _addIntegration,
                              icon: const Icon(Icons.add_rounded, size: 18),
                              label: Text(tr(context, 'Add')),
                            ),
                            children: [
                              if (_integrations.isEmpty)
                                Text(
                                  tr(context, 'No integrations yet. Sync from Firebase or add one.'),
                                  style: const TextStyle(
                                    color: AppColors.textMutedLight,
                                  ),
                                )
                              else
                                for (var i = 0; i < _integrations.length; i++)
                                  _integrationCard(i),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _syncing ? null : _syncFromFirebase,
                                  icon: _syncing
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.cloud_download_outlined,
                                          size: 18),
                                  label: Text(
                                    tr(context, 'Sync from Firebase'),
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: AppColors.brandNavy,
                                    side: const BorderSide(
                                      color: Color(0xFFCBD5E1),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 16,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: FilledButton(
                                  onPressed: _saving ? null : _save,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: AppColors.brandNavy,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 16,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  child: _saving
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : Text(
                                          tr(context, 'Save'),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
      ),
    );
  }

  Widget _section(
    String title, {
    required List<Widget> children,
    Widget? trailing,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A0F172A),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: AppColors.brandNavy,
                  ),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _labeledField(String label, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondaryLight,
          ),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }

  InputDecoration _inputDeco({String? hint}) => InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: const Color(0xFFF8FAFC),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
      );

  Widget _integrationCard(int index) {
    final d = _integrations[index];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: d.isDefault ? AppColors.primary : const Color(0xFFE2E8F0),
          width: d.isDefault ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: d.name,
                  decoration: _inputDeco(hint: tr(context, 'Integration name')),
                ),
              ),
              IconButton(
                tooltip: tr(context, 'Delete'),
                onPressed: () => _removeIntegration(index),
                icon: const Icon(Icons.delete_outline_rounded,
                    color: AppColors.error),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _labeledField(
            tr(context, 'Client ID'),
            TextField(
              controller: d.clientId,
              decoration: _inputDeco(
                hint: d.hasClientId
                    ? tr(context, 'Saved — leave blank to keep')
                    : null,
              ),
            ),
          ),
          const SizedBox(height: 10),
          _labeledField(
            tr(context, 'Client secret'),
            TextField(
              controller: d.clientSecret,
              obscureText: d.obscureSecret,
              decoration: _inputDeco(
                hint: d.hasClientSecret
                    ? tr(context, 'Saved — leave blank to keep')
                    : null,
              ).copyWith(
                suffixIcon: IconButton(
                  onPressed: () =>
                      setState(() => d.obscureSecret = !d.obscureSecret),
                  icon: Icon(
                    d.obscureSecret
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          _labeledField(
            tr(context, 'Device serial'),
            TextField(
              controller: d.serial,
              decoration: _inputDeco(),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _labeledField(
                  tr(context, 'Branch code'),
                  TextField(
                    controller: d.branchCode,
                    decoration: _inputDeco(hint: '0'),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _labeledField(
                  tr(context, 'Order types'),
                  TextField(
                    controller: d.orderTypes,
                    decoration: _inputDeco(
                      hint: 'Dine-in, Take Away',
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _labeledField(
            tr(context, 'Address'),
            TextField(
              controller: d.addressLine,
              decoration: _inputDeco(
                hint: tr(context, 'Governate · City · Street · Building'),
              ),
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: d.isDefault,
            activeColor: AppColors.primary,
            title: Text(
              tr(context, 'Default integration'),
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.brandNavy,
              ),
            ),
            onChanged: (_) => _setDefault(index),
          ),
        ],
      ),
    );
  }
}

class _IntegrationDraft {
  _IntegrationDraft({
    required this.id,
    String name = '',
    String clientId = '',
    String clientSecret = '',
    String serial = '',
    String branchCode = '0',
    String orderTypes = '',
    String addressLine = '',
    this.isDefault = false,
    this.hasClientId = false,
    this.hasClientSecret = false,
  })  : name = TextEditingController(text: name),
        clientId = TextEditingController(text: clientId),
        clientSecret = TextEditingController(text: clientSecret),
        serial = TextEditingController(text: serial),
        branchCode = TextEditingController(text: branchCode),
        orderTypes = TextEditingController(text: orderTypes),
        addressLine = TextEditingController(text: addressLine);

  factory _IntegrationDraft.fromModel(SiteTaxIntegration i) {
    final addr = [
      i.addressGovernate,
      i.addressRegionCity,
      i.addressStreet,
      i.addressBuildingNumber,
    ].where((s) => s.trim().isNotEmpty).join(' · ');
    return _IntegrationDraft(
      id: i.id,
      name: i.name,
      serial: i.serialNumber,
      branchCode: i.branchCode,
      orderTypes: i.orderTypes.join(', '),
      addressLine: addr,
      isDefault: i.isDefault,
      hasClientId: i.hasClientId,
      hasClientSecret: i.hasClientSecret,
    );
  }

  final String id;
  final TextEditingController name;
  final TextEditingController clientId;
  final TextEditingController clientSecret;
  final TextEditingController serial;
  final TextEditingController branchCode;
  final TextEditingController orderTypes;
  final TextEditingController addressLine;
  bool isDefault;
  bool hasClientId;
  bool hasClientSecret;
  bool obscureSecret = true;

  void dispose() {
    name.dispose();
    clientId.dispose();
    clientSecret.dispose();
    serial.dispose();
    branchCode.dispose();
    orderTypes.dispose();
    addressLine.dispose();
  }

  SiteTaxIntegration toModel() {
    final parts = addressLine.text
        .split('·')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return SiteTaxIntegration(
      id: id,
      name: name.text.trim(),
      clientId: clientId.text.trim(),
      clientSecret: clientSecret.text.trim(),
      serialNumber: serial.text.trim(),
      branchCode: branchCode.text.trim().isEmpty ? '0' : branchCode.text.trim(),
      isDefault: isDefault,
      orderTypes: [
        for (final t in orderTypes.text.split(','))
          if (t.trim().isNotEmpty) t.trim(),
      ],
      addressCountry: 'EG',
      addressGovernate: parts.isNotEmpty ? parts[0] : '',
      addressRegionCity: parts.length > 1 ? parts[1] : '',
      addressStreet: parts.length > 2 ? parts[2] : '',
      addressBuildingNumber: parts.length > 3 ? parts[3] : '',
      hasClientId: hasClientId,
      hasClientSecret: hasClientSecret,
    );
  }
}
