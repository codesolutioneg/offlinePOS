import '../../domain/order.dart';
import '../../domain/table_section_config.dart';
import '../db/settings_store.dart';
import '../db/table_store.dart';
import '../printing/printer_registry.dart';
import 'dishflow_config_client.dart';

/// What one Dishflow branch holds about its floor and its printers, as read.
class DishflowFloorSnapshot {
  const DishflowFloorSnapshot({
    this.tables = const [],
    this.sections = const [],
    this.printerDocs = const [],
    this.customCategories = const [],
    this.branchId = '',
    this.otherBranches = const {},
  });

  /// `tables` documents for the branch (tables, spacers and row breaks alike).
  final List<DishflowDoc> tables;

  /// `table_settings/{branchId}.sections`, in the order the manager arranged them.
  final List<Map<String, dynamic>> sections;

  /// Every `printer_settings` document, `global` among them.
  final List<DishflowDoc> printerDocs;

  /// `custom_pos_categories`: the ids section rules are saved against.
  final List<DishflowDoc> customCategories;

  /// The branch that was asked for, as typed.
  final String branchId;

  /// When [branchId] matched no table: the branch ids that do have tables, each
  /// with its name where the project records one. A mistyped id is the usual
  /// reason a read comes back with printers and no floor.
  final Map<String, String> otherBranches;

  /// Read one branch. [branchId] empty means the project holds a single branch.
  static Future<DishflowFloorSnapshot> fetch(
    DishflowConfigClient client, {
    required String projectId,
    required String apiKey,
    String branchId = '',
  }) async {
    Future<List<DishflowDoc>> list(String collection) => client.listCollection(
        projectId: projectId, apiKey: apiKey, collection: collection);

    final allTables = await list('tables');
    final tables = branchId.isEmpty
        ? allTables
        : [
            for (final t in allTables)
              if ('${t.fields['branchId'] ?? ''}' == branchId) t,
          ];

    Map<String, dynamic>? settingsDoc;
    if (branchId.isNotEmpty) {
      settingsDoc = await client.getDocument(
          projectId: projectId,
          apiKey: apiKey,
          path: 'table_settings/$branchId');
    } else {
      // No branch id to key on: only unambiguous when the project has one doc.
      final all = await list('table_settings');
      if (all.length == 1) settingsDoc = all.single.fields;
    }
    final rawSections = settingsDoc?['sections'];

    final otherBranches = <String, String>{};
    if (branchId.isNotEmpty && tables.isEmpty && allTables.isNotEmpty) {
      final names = {
        for (final b in await list('branches')) b.id: '${b.fields['name'] ?? ''}',
      };
      for (final t in allTables) {
        final id = '${t.fields['branchId'] ?? ''}';
        if (id.isNotEmpty) otherBranches[id] = names[id] ?? '';
      }
    }

    return DishflowFloorSnapshot(
      tables: tables,
      sections: [
        if (rawSections is List)
          for (final s in rawSections)
            if (s is Map) s.cast<String, dynamic>(),
      ],
      printerDocs: await list('printer_settings'),
      customCategories: await list('custom_pos_categories'),
      branchId: branchId,
      otherBranches: otherBranches,
    );
  }
}

/// A printer to configure, named the way the kitchen routing refers to it.
class ImportedPrinter {
  const ImportedPrinter({
    required this.name,
    this.host,
    this.port = 9100,
    this.backup,
    this.localRole,
  });

  final String name;
  final String? host;
  final int port;
  final String? backup;

  /// `receipt` or `delivery` when this is the branch's default for that job.
  ///
  /// Kept apart from [name] because Dishflow also routes kitchen slips to these
  /// printers by name, and that routing has to mean the same printer on every
  /// till, while `receipt` here means whichever one sits next to this till.
  final String? localRole;
}

/// What an import would write, worked out before anything is written so a
/// manager can read it first.
class FloorImportPlan {
  const FloorImportPlan({
    this.tables = const [],
    this.sectionConfigs = const [],
    this.printers = const [],
    this.categoryStations = const {},
    this.productStations = const {},
    this.subReceiptStation,
    this.notes = const [],
  });

  final List<PosTable> tables;
  final List<TableSectionConfig> sectionConfigs;
  final List<ImportedPrinter> printers;
  final Map<int, List<String>> categoryStations;
  final Map<int, List<String>> productStations;
  final String? subReceiptStation;

  /// Everything that did not carry over as-is, in plain words for the preview.
  final List<String> notes;

  bool get isEmpty =>
      tables.isEmpty &&
      sectionConfigs.isEmpty &&
      printers.isEmpty &&
      categoryStations.isEmpty &&
      productStations.isEmpty;

  List<String> get sections {
    final seen = <String>[];
    for (final t in tables) {
      if (!seen.contains(t.section)) seen.add(t.section);
    }
    return seen;
  }
}

/// Turns a Dishflow branch's floor and printer settings into this till's shapes.
///
/// Pure: reads a snapshot, returns a plan. Nothing is fetched or written here.
class DishflowFloorMapper {
  DishflowFloorMapper._();

  /// [categoryOfProduct] answers a product's menu category from the local
  /// catalogue. Dishflow prints a product at its own printers *and* its
  /// category's; this till lets a product's routing replace its category's, so
  /// the two are merged here to print the same slips.
  static FloorImportPlan plan(
    DishflowFloorSnapshot snapshot, {
    int? Function(int productId)? categoryOfProduct,
  }) {
    final notes = <String>[];
    if (snapshot.otherBranches.isNotEmpty) {
      notes.add('No tables are saved under branch id "${snapshot.branchId}". '
          'Branch ids that have tables: ${[
        for (final e in snapshot.otherBranches.entries)
          e.value.isEmpty ? e.key : '${e.key} (${e.value})',
      ].join(', ')}. Correct the branch id under Dishflow owner mirror.');
    }
    final tables = _tables(snapshot, notes);
    final sectionConfigs = _sectionConfigs(snapshot, notes);

    final source = _printerSource(snapshot.printerDocs);
    final names = _printerNames(source, notes);
    final printers = _printers(source, names);
    final categoryStations =
        _stations(_rows(source['settings']), names, notes, what: 'category');
    final ownProductStations = _stations(
        _rows(source['productSettings']), names, notes,
        what: 'product');

    final productStations = <int, List<String>>{};
    for (final e in ownProductStations.entries) {
      final merged = [...e.value];
      final category = categoryOfProduct?.call(e.key);
      for (final s in categoryStations[category] ?? const <String>[]) {
        if (!merged.contains(s)) merged.add(s);
      }
      productStations[e.key] = merged;
    }

    final routed = {
      for (final v in categoryStations.values) ...v,
      for (final v in productStations.values) ...v,
    };
    if (routed.isNotEmpty && !names.containsValue('kitchen')) {
      notes.add('No printer is named "kitchen". Items with no routing print '
          'there on this till, so add one or route every category.');
    }

    final subId = '${source['defaultSubReceiptPrinterId'] ?? ''}';
    return FloorImportPlan(
      tables: tables,
      sectionConfigs: sectionConfigs,
      printers: printers,
      categoryStations: categoryStations,
      productStations: productStations,
      subReceiptStation: names[subId],
      notes: notes,
    );
  }

  // ── tables ───────────────────────────────────────────────────────

  static List<PosTable> _tables(
      DishflowFloorSnapshot snapshot, List<String> notes) {
    final sectionOrder = [
      for (final s in snapshot.sections) '${s['name'] ?? ''}'.trim(),
    ];
    final gridCols = {
      for (final s in snapshot.sections)
        '${s['name'] ?? ''}'.trim(): _int(s['gridCols']) ?? 6,
    };

    final real = [
      for (final t in snapshot.tables)
        if ('${t.fields['type'] ?? 'table'}' == 'table') t,
    ]..sort((a, b) => (_int(a.fields['number']) ?? 0)
        .compareTo(_int(b.fields['number']) ?? 0));

    final taken = <String, Set<String>>{};
    final usedNames = <String>{};
    final out = <PosTable>[];
    final unplaced = <DishflowDoc>[];

    String sectionOf(DishflowDoc t) {
      final s = '${t.fields['section'] ?? ''}'.trim();
      return s.isEmpty ? 'Main' : s;
    }

    void add(DishflowDoc t, int col, int row) {
      final section = sectionOf(t);
      final number = _int(t.fields['number']) ?? 0;
      // The bill is recalled by name and Dishflow restarts numbering in every
      // section, so the section goes into the name to keep it unique.
      var name = '$section $number';
      for (var n = 2; !usedNames.add(name); n++) {
        name = '$section $number-$n';
      }
      var index = sectionOrder.indexOf(section);
      if (index < 0) {
        sectionOrder.add(section);
        index = sectionOrder.length - 1;
      }
      taken.putIfAbsent(section, () => {}).add('$col:$row');
      out.add(PosTable(
        id: t.id,
        name: name,
        section: section,
        seats: _int(t.fields['seats']) ?? 4,
        x: col.toDouble(),
        y: row.toDouble(),
        sequence: index * 1000 + number,
        shape: switch ('${t.fields['shape'] ?? ''}') {
          'circle' => TableShape.round,
          'square' => TableShape.square,
          _ => TableShape.rectangle,
        },
        displayLabel: '${t.fields['label'] ?? ''}'.trim(),
      ));
    }

    for (final t in real) {
      final col = _int(t.fields['gridCol']);
      final row = _int(t.fields['gridRow']);
      final cells = taken[sectionOf(t)] ?? const <String>{};
      if (col == null || row == null || cells.contains('$col:$row')) {
        unplaced.add(t);
      } else {
        add(t, col, row);
      }
    }

    // Tables Dishflow never placed, or stacked on a cell already used, take the
    // next free cell so nothing lands on top of anything else.
    for (final t in unplaced) {
      final section = sectionOf(t);
      final cols = gridCols[section] ?? 6;
      final cells = taken[section] ?? const <String>{};
      var i = 0;
      while (cells.contains('${i % cols}:${i ~/ cols}')) {
        i++;
      }
      add(t, i % cols, i ~/ cols);
    }
    if (unplaced.isNotEmpty) {
      notes.add('${unplaced.length} table(s) had no free grid position and '
          'were placed on the next empty cell.');
    }

    final empty = [
      for (final s in sectionOrder)
        if (s.isNotEmpty && !out.any((t) => t.section == s)) s,
    ];
    if (empty.isNotEmpty) {
      notes.add('Sections with no tables are not created: ${empty.join(', ')}.');
    }
    return out;
  }

  // ── section rules ────────────────────────────────────────────────

  static List<TableSectionConfig> _sectionConfigs(
      DishflowFloorSnapshot snapshot, List<String> notes) {
    // Dishflow saves section rules against its own category document ids; this
    // till filters on the Odoo ids those documents point at.
    final odooIdOf = <String, int>{
      for (final c in snapshot.customCategories)
        if (_int(c.fields['odooId']) != null) c.id: _int(c.fields['odooId'])!,
    };

    final out = <TableSectionConfig>[];
    for (final s in snapshot.sections) {
      final name = '${s['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;

      var unmapped = 0;
      int? category(Object? raw) {
        final id = odooIdOf['$raw'] ?? int.tryParse('$raw');
        if (id == null) unmapped++;
        return id;
      }

      final rawCategories = _list(s['allowedCategoryIds']);
      final categories = [
        for (final raw in rawCategories)
          if (category(raw) case final int id) id,
      ];
      if (rawCategories.isNotEmpty && categories.isEmpty) {
        notes.add('Section "$name": none of its allowed categories could be '
            'matched, so it would show the whole menu. Set them by hand.');
      } else if (unmapped > 0) {
        notes.add('Section "$name": $unmapped allowed category id(s) had no '
            'Odoo category and were left out.');
      }

      final employees = <String, List<String>>{};
      final rawEmployees = s['employeeAllowedCategories'];
      if (rawEmployees is Map) {
        for (final e in rawEmployees.entries) {
          final ids = _list(e.value);
          employees['${e.key}'] = ids.length == 1 &&
                  '${ids.first}' == TableSectionConfig.allCategoriesSentinel
              ? [TableSectionConfig.allCategoriesSentinel]
              : [
                  for (final raw in ids)
                    if (category(raw) case final int id) '$id',
                ];
        }
      }

      final typeRaw = s['defaultOrderType'];
      final type = typeRaw == null ? null : _orderType('$typeRaw');
      if (typeRaw != null && type == null) {
        notes.add('Section "$name": default order type "$typeRaw" is not '
            'known here and was left unset.');
      }

      out.add(TableSectionConfig(
        name: name,
        isStaffSection: s['isStaffSection'] == true,
        allowedCategoryIds: categories,
        allowedPaymentMethodIds: [
          for (final raw in _list(s['allowedPaymentMethodIds']))
            if (int.tryParse('$raw') case final int id) id,
        ],
        employeeAllowedCategories: employees,
        requireGuestCount:
            s['requireGuestCount'] is bool ? s['requireGuestCount'] as bool : null,
        defaultOrderType: type,
      ));
    }
    return out;
  }

  /// Null for a name this till has no type for. Not [OrderTypeLabel.parse],
  /// which answers dine-in for anything it does not recognise.
  static OrderType? _orderType(String raw) =>
      switch (raw.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '')) {
        'dinein' => OrderType.dineIn,
        'takeaway' => OrderType.takeaway,
        'togo' => OrderType.toGo,
        'deliveryfromcompany' => OrderType.deliveryFromCompany,
        'cardelivery' => OrderType.carDelivery,
        'storedelivery' || 'delivery' => OrderType.storeDelivery,
        _ => null,
      };

  // ── printers and routing ─────────────────────────────────────────

  /// The document Dishflow itself would print from: `global` when it lists
  /// printers, otherwise every user's document merged, first one winning.
  static Map<String, dynamic> _printerSource(List<DishflowDoc> docs) {
    for (final d in docs) {
      if (d.id == 'global' && _rows(d.fields['printers']).isNotEmpty) {
        return d.fields;
      }
    }
    final merged = <String, dynamic>{};
    for (final key in const ['printers', 'settings', 'productSettings']) {
      final idField = key == 'printers' ? 'id' : 'category_id';
      final seen = <String>{};
      merged[key] = [
        for (final d in docs)
          for (final row in _rows(d.fields[key]))
            if (seen.add('${row[idField]}')) row,
      ];
    }
    for (final key in const [
      'defaultReceiptPrinterId',
      'defaultDeliveryPrinterId',
      'defaultSubReceiptPrinterId',
    ]) {
      for (final d in docs) {
        final v = '${d.fields[key] ?? ''}';
        if (v.isNotEmpty) {
          merged[key] = v;
          break;
        }
      }
    }
    return merged;
  }

  /// Dishflow printer id → the name this till will know it by.
  static Map<String, String> _printerNames(
      Map<String, dynamic> source, List<String> notes) {
    final names = <String, String>{};
    for (final p in _rows(source['printers'])) {
      final id = '${p['id'] ?? ''}';
      if (id.isEmpty) continue;
      var name = '${p['name'] ?? ''}'.trim();
      if (name.isEmpty) name = id;
      final base = name;
      for (var n = 2; names.containsValue(name); n++) {
        name = '$base $n';
      }
      if (name != base) {
        notes.add('Two printers are called "$base"; one was renamed "$name".');
      }
      names[id] = name;
    }
    return names;
  }

  static List<ImportedPrinter> _printers(
          Map<String, dynamic> source, Map<String, String> names) =>
      [
        for (final p in _rows(source['printers']))
          if (names['${p['id'] ?? ''}'] case final String name)
            ImportedPrinter(
              name: name,
              host: switch ('${p['ip_address'] ?? ''}'.trim()) {
                '' => null,
                final host => host,
              },
              port: _int(p['port']) ?? 9100,
              backup: names['${p['fallback_printer_id'] ?? ''}'],
              localRole: switch ('${p['id']}') {
                final id when id == '${source['defaultReceiptPrinterId']}' =>
                  'receipt',
                final id when id == '${source['defaultDeliveryPrinterId']}' =>
                  'delivery',
                _ => null,
              },
            ),
      ];

  static Map<int, List<String>> _stations(
    List<Map<String, dynamic>> rows,
    Map<String, String> names,
    List<String> notes, {
    required String what,
  }) {
    final out = <int, List<String>>{};
    var missing = 0;
    for (final row in rows) {
      final id = _int(row['category_id']);
      if (id == null || id <= 0) continue;
      final multi = _list(row['kitchen_printers']);
      final ids = multi.isNotEmpty
          ? multi
          : [
              if ('${row['kitchen_printer'] ?? ''}'.isNotEmpty)
                row['kitchen_printer'],
            ];
      final stations = <String>[];
      for (final printerId in ids) {
        final name = names['$printerId'];
        if (name == null) {
          missing++;
        } else if (!stations.contains(name)) {
          stations.add(name);
        }
      }
      if (stations.isNotEmpty) out[id] = stations;
    }
    if (missing > 0) {
      notes.add('$missing $what routing entr${missing == 1 ? 'y points' : 'ies point'} '
          'at a printer that no longer exists and ${missing == 1 ? 'was' : 'were'} skipped.');
    }
    return out;
  }

  // ── decoding helpers ─────────────────────────────────────────────

  static int? _int(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('${v ?? ''}'));

  static List<Object?> _list(Object? v) => v is List ? v : const [];

  static List<Map<String, dynamic>> _rows(Object? v) => [
        for (final row in _list(v))
          if (row is Map) row.cast<String, dynamic>(),
      ];
}

/// Writes a [FloorImportPlan] through the stores the till already uses, so the
/// floor and the section rules reach the other tills the way a hand edit would.
class DishflowFloorImporter {
  DishflowFloorImporter({
    required this.tables,
    required this.settings,
    required this.printers,
  });

  final TableStore tables;
  final SettingsStore settings;
  final PrinterRegistry printers;

  /// [replaceFloor] removes tables the plan does not contain; otherwise they
  /// stay and an incoming table that shares a name with one is renamed.
  ///
  /// The caller is expected to have checked that no order is open: a bill is
  /// recalled by its table name, and renaming the floor under one loses it.
  void apply(FloorImportPlan plan, {required bool replaceFloor}) {
    if (plan.tables.isNotEmpty) {
      if (replaceFloor) {
        final incoming = {for (final t in plan.tables) t.id};
        for (final existing in tables.all()) {
          if (!incoming.contains(existing.id)) tables.remove(existing.id);
        }
      }
      for (final t in plan.tables) {
        final clash = tables.byName(t.name);
        tables.upsert(clash == null || clash.id == t.id
            ? t
            : t.copyWith(name: tables.uniqueName(t.name)));
      }
    }

    for (final config in plan.sectionConfigs) {
      settings.setSectionConfig(config);
    }

    for (final p in plan.printers) {
      // Pinned: the address is the one the shop typed into Dishflow, not one a
      // sweep guessed.
      printers.remember(p.name, host: p.host, port: p.port, pinned: true);
      // This till's own receipt and delivery printers are only filled in when
      // empty: the branch default may be another counter's drawer.
      final role = p.localRole;
      if (role != null && role != p.name && printers[role] == null) {
        printers.remember(role, host: p.host, port: p.port, pinned: true);
      }
    }
    for (final p in plan.printers) {
      if (p.backup != null) printers.setBackup(p.name, p.backup);
    }

    if (plan.categoryStations.isNotEmpty) {
      settings.categoryStations = {
        ...settings.categoryStations,
        ...plan.categoryStations,
      };
    }
    if (plan.productStations.isNotEmpty) {
      settings.productStations = {
        ...settings.productStations,
        ...plan.productStations,
      };
    }
    final sub = plan.subReceiptStation;
    if (sub != null && settings.subReceiptStation.isEmpty) {
      settings.subReceiptStation = sub;
    }
  }
}
