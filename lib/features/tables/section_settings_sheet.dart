import 'package:flutter/material.dart';

import '../../core/db/catalogue_store.dart';
import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../domain/catalogue.dart';
import '../../domain/table_section_config.dart';

/// Edit one floor section: staff toggle, allowed categories, payments, and
/// optional per-employee category overrides.
class SectionSettingsSheet extends StatefulWidget {
  const SectionSettingsSheet({
    super.key,
    required this.section,
    required this.settings,
    required this.catalogue,
    this.staff = const [],
  });

  final String section;
  final SettingsStore settings;
  final CatalogueStore catalogue;
  final List<({String id, String name, bool active})> staff;

  @override
  State<SectionSettingsSheet> createState() => _SectionSettingsSheetState();
}

class _SectionSettingsSheetState extends State<SectionSettingsSheet> {
  late bool _staff;
  late Set<int> _cats;
  late Set<int> _pays;
  late Map<String, List<String>> _employeeCats;

  @override
  void initState() {
    super.initState();
    final cfg = widget.settings.sectionConfig(widget.section);
    _staff = cfg.isStaffSection;
    _cats = {...cfg.allowedCategoryIds};
    _pays = {...cfg.allowedPaymentMethodIds};
    _employeeCats = {
      for (final e in cfg.employeeAllowedCategories.entries) e.key: [...e.value],
    };
  }

  void _save() {
    if (widget.settings.deviceRole == DeviceRole.secondary) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(context,
              'Section rules are owned by the primary till. Join as primary to edit.'))));
      return;
    }
    widget.settings.setSectionConfig(TableSectionConfig(
      name: widget.section,
      isStaffSection: _staff,
      allowedCategoryIds: _cats.toList()..sort(),
      allowedPaymentMethodIds: _pays.toList()..sort(),
      employeeAllowedCategories: _staff ? _employeeCats : const {},
    ));
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final cats = widget.catalogue.categories();
    final pays = widget.catalogue.paymentMethods();
    final employees = [
      for (final s in widget.staff)
        if (s.active && s.name.trim().isNotEmpty) s.name.trim(),
    ]..sort();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (ctx, scroll) => SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${tr(ctx, 'Section settings')}: ${widget.section}',
                      style: Theme.of(ctx).textTheme.titleLarge,
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(tr(ctx, 'Cancel')),
                  ),
                  FilledButton(
                    key: const Key('section-settings-save'),
                    onPressed: _save,
                    child: Text(tr(ctx, 'Save')),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  SwitchListTile(
                    key: const Key('section-staff-toggle'),
                    title: Text(tr(ctx, 'Staff section')),
                    subtitle: Text(tr(ctx,
                        'Restrict the menu and payments; optional rules per employee')),
                    value: _staff,
                    onChanged: (v) => setState(() => _staff = v),
                  ),
                  const SizedBox(height: 8),
                  Text(tr(ctx, 'Allowed categories'),
                      style: Theme.of(ctx).textTheme.titleMedium),
                  Text(tr(ctx, 'Empty means every category'),
                      style: Theme.of(ctx).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in cats)
                        FilterChip(
                          key: Key('section-cat-${c.id}'),
                          label: Text(c.name),
                          selected: _cats.contains(c.id),
                          onSelected: (on) => setState(() {
                            if (on) {
                              _cats.add(c.id);
                            } else {
                              _cats.remove(c.id);
                            }
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(tr(ctx, 'Allowed payment methods'),
                      style: Theme.of(ctx).textTheme.titleMedium),
                  Text(tr(ctx, 'Empty means every method'),
                      style: Theme.of(ctx).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final m in pays)
                        FilterChip(
                          key: Key('section-pay-${m.id}'),
                          label: Text(m.name),
                          selected: _pays.contains(m.id),
                          onSelected: (on) => setState(() {
                            if (on) {
                              _pays.add(m.id);
                            } else {
                              _pays.remove(m.id);
                            }
                          }),
                        ),
                    ],
                  ),
                  if (_staff && employees.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text(tr(ctx, 'Per-employee categories'),
                        style: Theme.of(ctx).textTheme.titleMedium),
                    Text(
                      tr(ctx,
                          'Inherit section, allow all, or pick categories for each person'),
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    for (final name in employees)
                      _EmployeeOverrideTile(
                        name: name,
                        categories: cats,
                        selected: _employeeCats[name],
                        onChanged: (next) => setState(() {
                          if (next == null) {
                            _employeeCats.remove(name);
                          } else {
                            _employeeCats[name] = next;
                          }
                        }),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmployeeOverrideTile extends StatelessWidget {
  const _EmployeeOverrideTile({
    required this.name,
    required this.categories,
    required this.selected,
    required this.onChanged,
  });

  final String name;
  final List<Category> categories;
  final List<String>? selected;
  final void Function(List<String>?) onChanged;

  bool get _isAll =>
      selected != null &&
      selected!.length == 1 &&
      selected!.first == TableSectionConfig.allCategoriesSentinel;

  bool get _isInherit => selected == null;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(
                    value: 'inherit', label: Text(tr(context, 'Inherit'))),
                ButtonSegment(value: 'all', label: Text(tr(context, 'All'))),
                ButtonSegment(value: 'pick', label: Text(tr(context, 'Pick'))),
              ],
              selected: {
                if (_isInherit) 'inherit' else if (_isAll) 'all' else 'pick',
              },
              onSelectionChanged: (s) {
                final mode = s.first;
                if (mode == 'inherit') {
                  onChanged(null);
                } else if (mode == 'all') {
                  onChanged([TableSectionConfig.allCategoriesSentinel]);
                } else {
                  onChanged(const []);
                }
              },
            ),
            if (!_isInherit && !_isAll) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final c in categories)
                    FilterChip(
                      label: Text(c.name),
                      selected: (selected ?? const []).contains('${c.id}'),
                      onSelected: (on) {
                        final next = {...?selected};
                        if (on) {
                          next.add('${c.id}');
                        } else {
                          next.remove('${c.id}');
                        }
                        onChanged(next.toList());
                      },
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
