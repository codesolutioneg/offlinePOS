import 'dart:convert';
import 'dart:typed_data';

import '../../domain/catalogue.dart';
import 'odoo_site.dart';

/// What a pull is allowed to ask for beyond the menu itself.
///
/// Pictures are the only part of the catalogue that is measured in megabytes, so a
/// shop that does not show them on the grid does not download them either. Published
/// by [SettingsStore] the way the print profile is, because the puller is built once
/// at startup and the switch can be flipped at any point after that.
class CataloguePullOptions {
  const CataloguePullOptions({this.images = false});

  static CataloguePullOptions shared = const CataloguePullOptions();

  final bool images;
}

/// Fetches the catalogue from Odoo and maps it into local models.
///
/// The counterpart to [OdooSender]. Runs on a schedule and never on the path of a
/// sale, so a slow or absent server delays a refresh but never a customer.
class OdooPuller {
  OdooPuller({
    required this.call,
    this.withImages,
    this.branchId,
    this.userId,
    int? Function()? restaurantId,
    int? Function()? companyId,
  })  : restaurantId = restaurantId ?? (() => OdooSite.shared.restaurantId),
        companyId = companyId ?? (() => OdooSite.shared.branchId);

  /// The company this till's money belongs to, which is what a journal is scoped by.
  ///
  /// Read off the published [OdooSite] like [restaurantId], and deliberately not off
  /// [branchId]: that one narrows the *menu* and is a branch record, while a journal
  /// is company-scoped and jouma runs a company per branch. Null asks for every
  /// journal the login can see, which is what a single-company shop wants.
  final int? Function() companyId;

  /// The point of sale this till sells through, which narrows the pick lists a
  /// manager links a local dish or category against.
  ///
  /// A reader for the same reason [branchId] and [userId] are: everything a manager
  /// can change after startup is read at the moment it is used, not captured when
  /// the puller was built. It falls back to the published [OdooSite] so a caller
  /// that names no reader still asks the question the whole app answers it with.
  final int? Function() restaurantId;

  /// The Odoo user this till is logged in as, so the tender list can be narrowed to
  /// the journals that user is allowed to take money on.
  ///
  /// A reader for the same reason [branchId] is one: the puller is built before the
  /// endpoint is configured, and the login can change under it. Null, or a null
  /// answer, narrows nothing, which is what a till that has not authenticated yet
  /// and a test with a stubbed server both want.
  final int? Function()? userId;

  /// The branch this till sells for, so a chain's other menus stay off it.
  ///
  /// A reader rather than a value because the puller is built once at startup and
  /// a manager can move the till to another branch at any point after that. Read
  /// at the moment of the pull, the next refresh is already the new menu. Null, or
  /// a null answer, pulls everything, which is what a single-shop till wants and
  /// what every till did before branches existed.
  final int? Function()? branchId;

  /// Performs one Odoo `call_kw`. Injected so this is testable without a socket.
  final Future<dynamic> Function(String model, String method, List<dynamic> args,
      Map<String, dynamic> kwargs) call;

  /// Overrides the published option, for a test that wants one answer whatever the
  /// device is set to. Null reads the shop's own choice at the moment of the pull.
  final bool? withImages;

  bool get _wantsImages => withImages ?? CataloguePullOptions.shared.images;

  /// The menu this till should show: everything sold in its branch, plus
  /// everything nobody restricted to a branch at all.
  ///
  /// A chain lists a product against the branches that sell it, and an empty list
  /// means every branch, which is the convention Odoo's own company_id already
  /// uses and the reason installing branches hides nothing that was visible
  /// yesterday.
  ///
  /// Two ways this asks for less than it wants, both deliberate. With no branch
  /// configured it asks for the whole menu, because a single-shop till has no
  /// branch to filter by and never had one. And an Odoo without the branches field
  /// answers the filtered read with an error rather than an empty menu, so that is
  /// caught and the whole menu pulled instead: a till showing a few extra dishes is
  /// a nuisance, and a till showing none cannot trade.
  Future<List<Map<String, dynamic>>> _productsForBranch() async {
    const fields = ['id', 'display_name', 'lst_price', 'pos_categ_ids', 'barcode',
        'active', 'to_weight', 'taxes_id', 'product_tmpl_id'];
    final extras = ['standard_price', if (_wantsImages) 'image_128'];
    const inPos = ['available_in_pos', '=', true];

    final branch = branchId?.call();
    if (branch != null && _branchFieldMissing != true) {
      try {
        final byBranch =
            await _searchReadOptional('product.product', fields, extras, [
          inPos,
          '|',
          ['product_tmpl_id.branch_ids', '=', false],
          ['product_tmpl_id.branch_ids', 'in', [branch]],
        ]);
        _branchFieldMissing = false;
        return byBranch;
      } catch (e) {
        // Only an answer that says the field is not there earns the whole menu.
        // The retry inside the read above probes each optional field before giving
        // up, so asking an Odoo without the field on every refresh would spend a
        // handful of failing calls each time to learn the same thing, which is why
        // that case is remembered.
        //
        // A timeout or a 500 says nothing about branches. Falling through to the
        // unfiltered read on one would hand a chain's till the whole chain's menu
        // for that refresh, so the failure is thrown on instead: the refresh gives
        // up, the till keeps the branch menu it already had, and the next pass
        // tries again. A stale correct menu beats a fresh wrong one.
        if (!_readsAsUnknownField(e)) rethrow;
        _branchFieldMissing = true;
      }
    }
    return _searchReadOptional('product.product', fields, extras, [inPos]);
  }

  /// Whether this Odoo has the branches field, learned by asking once. Null until
  /// the first attempt. Held for the life of the puller rather than persisted: an
  /// addon installed while the till is running is picked up at its next restart,
  /// which is soon enough for something that happens once.
  bool? _branchFieldMissing;

  /// Whether a failure is Odoo saying it has never heard of the branches field, as
  /// opposed to the network or the server having a bad moment.
  ///
  /// Matched on the message because that is all a JSON-RPC fault gives us, and both
  /// halves have to be in it: a complaint about a field, and our field named in the
  /// same breath. Either half alone latches the whole chain's menu onto a branch
  /// till over something else entirely. "Does not exist" is how Odoo reports a
  /// record deleted under a read, which is a passing failure and says nothing about
  /// the addon; and any fault that carries a traceback quotes back the domain we
  /// sent, `branch_ids` and all, whatever actually went wrong.
  ///
  /// Read conservatively: anything unrecognised is treated as a passing failure, so
  /// the worst an unfamiliar wording costs is asking again next refresh.
  static final _unknownBranchField = RegExp(
      r'(invalid field|unknown field|no such field|has no attribute)'
      r'[^\n]{0,80}branch_ids');

  static bool _readsAsUnknownField(Object error) =>
      _unknownBranchField.hasMatch(error.toString().toLowerCase());

  Future<CataloguePull> pull() async {
    final categories = await _searchRead(
      'pos.category',
      ['id', 'name', 'sequence', 'parent_id'],
      [],
    );
    // The cost and the picture are asked for as extras: an Odoo that will not give
    // one of them still gives up the menu, which is the only part a till cannot sell
    // without. Pictures are asked for only when the shop shows them.
    final products = await _productsForBranch();
    // Odoo links modifier groups to product *templates*; the till sells variants.
    // Map the template ids onto the product ids we actually loaded, or a product
    // with modifiers upstream would arrive with none here.
    final templateToProducts = <int, List<int>>{};
    for (final p in products) {
      final tmpl = _id(p['product_tmpl_id']) ?? p['id'] as int;
      templateToProducts.putIfAbsent(tmpl, () => []).add(p['id'] as int);
    }
    // Resolve each product's tax to a percent, so the till can show a tax
    // breakdown. Optional: an Odoo that refuses account.tax simply leaves tax at
    // zero rather than losing the catalogue.
    final taxRate = <int, double>{};
    try {
      final taxes = await _searchRead('account.tax',
          ['id', 'amount', 'amount_type'], [['amount_type', '=', 'percent']]);
      for (final t in taxes) {
        taxRate[t['id'] as int] = _num(t['amount']);
      }
    } catch (_) {
      // no tax data; taxRate stays empty
    }
    final modifiers = await _modifiers(templateToProducts);

    // The tenders for the payment sheet. Optional: an Odoo that will not answer
    // leaves the till on the tenders it already has. Whether the read happened at
    // all is carried separately, because a server that refused the question and a
    // shop that genuinely has none look identical from here, and only one of them is
    // a reason to forget the tenders this till is selling with.
    var tenders = const <PaymentMethod>[];
    var tendersRead = false;
    try {
      tenders = await _tenders();
      tendersRead = true;
    } catch (_) {
      tenders = const [];
    }

    // Customers for attaching a guest to a sale. Bounded so a large partner list
    // cannot bloat the till; optional like the rest.
    List<Map<String, dynamic>> partners = const [];
    try {
      final raw = await call('res.partner', 'search_read', [
        [['customer_rank', '>', 0]],
        ['id', 'name', 'phone', 'mobile']
      ], {'limit': 500, 'order': 'name'});
      partners = raw is List
          ? raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
          : const [];
    } catch (_) {
      partners = const [];
    }

    return CataloguePull(
      categories: categories
          .map((c) => Category(
                id: c['id'] as int,
                name: (c['name'] ?? '') as String,
                sequence: (c['sequence'] ?? 0) as int,
                parentId: _id(c['parent_id']),
              ))
          .toList(),
      products: products
          .map((p) => Product(
                id: p['id'] as int,
                name: (p['display_name'] ?? p['name'] ?? '') as String,
                price: _num(p['lst_price']),
                categoryId: _ids(p['pos_categ_ids']).firstOrNull,
                barcode: p['barcode'] is String ? p['barcode'] as String : null,
                active: p['active'] != false,
                soldByWeight: p['to_weight'] == true,
                // First percent tax on the product, or 0 when none is resolvable.
                taxRate: _ids(p['taxes_id'])
                    .map((id) => taxRate[id])
                    .whereType<double>()
                    .firstOrNull ??
                    0,
                cost: _num(p['standard_price']),
              ))
          .toList(),
      // A product the server gave no picture for is simply absent, which is what
      // leaves its tile the colour it is today.
      productImages: {
        for (final p in products) (p['id'] as int): ?_image(p['image_128']),
      },
      groups: modifiers.groups,
      productGroupIds: modifiers.productGroupIds,
      groupsRead: modifiers.read,
      modifierModel: modifiers.model,
      // Only worth reporting on a till that asked to be filtered. A single-shop
      // till has no branch, so the field being absent costs it nothing.
      branchFilterUnavailable:
          branchId?.call() != null && _branchFieldMissing == true,
      paymentMethods: tenders,
      paymentMethodsRead: tendersRead,
      customers: partners
          .map((c) => Customer(
                id: c['id'] as int,
                name: (c['name'] ?? '') as String,
                phone: c['phone'] is String
                    ? c['phone'] as String
                    : (c['mobile'] is String ? c['mobile'] as String : null),
              ))
          .toList(),
    );
  }

  /// The shop's modifier groups, from whichever add-on this database actually
  /// holds them in.
  ///
  /// Two unrelated add-ons put modifiers in the same database under different
  /// models, and a till cannot know which one a given shop installed. The
  /// `pos.product.modifier` pair is asked first because it is what the shops
  /// running today are on; the older `product.modifier.category` pair answers only
  /// when the first came back with nothing. Whichever set answers is used whole and
  /// the two are never merged: they number their groups from separate sequences, so
  /// mixing them would put two different groups on one id.
  ///
  /// A model that is not installed makes the read throw, which is why every read
  /// here degrades to no modifiers rather than losing the catalogue: products and
  /// categories are the part a till cannot sell without.
  ///
  /// Which pair answered is carried out with the groups. A shop with both add-ons
  /// installed shows nothing on the screen to say which one the options came from,
  /// so a support call about an option that will not appear starts by guessing at
  /// the wrong model.
  Future<_PulledModifiers> _modifiers(
      Map<int, List<int>> templateToProducts) async {
    final current = await _posModifiers(templateToProducts);
    if (current.groups.isNotEmpty) return current;
    final legacy = await _legacyModifiers(templateToProducts);
    if (legacy.groups.isNotEmpty) return legacy;
    // Neither had a row to give. Whether either could be read at all is still
    // worth carrying: an empty answer and a refused question look identical from
    // here, and only one of them is a reason to forget the groups the till has.
    return _PulledModifiers(const [], const {},
        read: current.read || legacy.read);
  }

  /// The `pos.product.modifier` / `pos.modifier.option` pair.
  Future<_PulledModifiers> _posModifiers(
      Map<int, List<int>> templateToProducts) async {
    final List<Map<String, dynamic>> groups;
    final List<Map<String, dynamic>> options;
    try {
      groups = await _searchReadOptional(
        'pos.product.modifier',
        ['id', 'name', 'sequence', 'product_tmpl_id', 'required', 'min_selection',
         'max_selection', 'display_type'],
        // price_mode decides whether an option adds to the dish's price or is it.
        // Optional so an add-on without the field still gives up its groups, and a
        // missing answer means 'add', which is the field's own default.
        ['auto_add', 'default_option_id', 'price_mode'],
        [
          ['active', '=', true]
        ],
      );
      options = await _searchReadOptional(
        'pos.modifier.option',
        ['id', 'name', 'modifier_id', 'price_extra', 'sequence', 'product_id'],
        // An upgrade names its surcharge separately, and that figure is already the
        // difference from the option the dish comes with, so it is what gets
        // charged rather than the option's own price.
        ['is_default', 'is_upgrade', 'upgrade_price'],
        [
          ['active', '=', true]
        ],
      );
    } catch (_) {
      return _PulledModifiers.unread;
    }

    // A group names its default either on the option or on the group itself, and
    // shops have both, so an option is a default when either of them says so.
    final namedDefaults = <int>{};
    for (final g in groups) {
      final id = _id(g['default_option_id']);
      if (id != null) namedDefaults.add(id);
    }
    // Whether a group's options replace the dish's price or add to it. Read off the
    // group because that is where Odoo keeps it, and applied to each of its options
    // below: 'add' is the default there and the assumption here.
    final replaces = <int>{};
    for (final g in groups) {
      if (g['price_mode'] == 'replace') replaces.add(g['id'] as int);
    }

    final byGroup = <int, List<Modifier>>{};
    for (final o in options) {
      final gid = _id(o['modifier_id']);
      if (gid == null) continue;
      // Three ways an option is priced, and picking the wrong one charges the
      // customer the wrong amount in silence.
      //
      // An upgrade carries its own surcharge, and that number is already the
      // difference from the option the dish comes with, so it is a flat addition
      // however its group is set. Otherwise a 'replace' group means the option's
      // price is the whole dish's price, and everything else adds.
      final upgrade = o['is_upgrade'] == true ? _num(o['upgrade_price']) : 0.0;
      final isUpgrade = o['is_upgrade'] == true && upgrade != 0;
      byGroup.putIfAbsent(gid, () => []).add(Modifier(
            id: o['id'] as int,
            groupId: gid,
            name: (o['name'] ?? '') as String,
            price: isUpgrade ? upgrade : _num(o['price_extra']),
            priceType: !isUpgrade && replaces.contains(gid)
                ? ModifierPriceType.replace
                : ModifierPriceType.fixed,
            sequence: (o['sequence'] ?? 0) as int,
            productId: _id(o['product_id']),
            isDefault:
                o['is_default'] == true || namedDefaults.contains(o['id']),
          ));
    }

    final mapped = <ModifierGroup>[];
    final byProduct = <int, List<int>>{};
    for (final g in groups) {
      final gid = g['id'] as int;
      mapped.add(ModifierGroup(
        id: gid,
        name: (g['name'] ?? '') as String,
        sequence: (g['sequence'] ?? 0) as int,
        minSelection: (g['min_selection'] ?? 0) as int,
        // A radio group is one choice by construction, and the server only holds
        // its own min/max to account for a checkbox, so a radio arrives as 0/0 and
        // would read here as "take as many as you like".
        //
        // A group whose options replace the dish's price is one choice too,
        // however it is displayed. A dish has one price, so two of them is not a
        // thing a bill can express: taken twice, the option's difference from the
        // dish is applied twice and the size is charged as though it were an
        // extra, which is the arithmetic this price mode exists to stop.
        maxSelection: g['display_type'] == 'radio' || replaces.contains(gid)
            ? 1
            : (g['max_selection'] ?? 0) as int,
        required: g['required'] == true,
        autoAdd: g['auto_add'] == true,
        modifiers: byGroup[gid] ?? const [],
      ));
      for (final pid
          in templateToProducts[_id(g['product_tmpl_id'])] ?? const <int>[]) {
        byProduct.putIfAbsent(pid, () => []).add(gid);
      }
    }
    return _PulledModifiers(mapped, byProduct, model: 'pos.product.modifier');
  }

  /// The older `product.modifier.category` / `product.modifier` pair.
  Future<_PulledModifiers> _legacyModifiers(
      Map<int, List<int>> templateToProducts) async {
    final List<Map<String, dynamic>> groups;
    final List<Map<String, dynamic>> modifiers;
    try {
      groups = await _searchReadOptional(
        'product.modifier.category',
        ['id', 'name', 'sequence', 'min_selection', 'max_selection', 'selection_type',
         'product_template_ids'],
        ['auto_add'],
        [
          ['active', '=', true]
        ],
      );
      modifiers = await _searchReadOptional(
        'product.modifier',
        ['id', 'name', 'category_id', 'price', 'price_type', 'sequence', 'product_id'],
        ['is_default'],
        [
          ['active', '=', true]
        ],
      );
    } catch (_) {
      return _PulledModifiers.unread;
    }

    final byGroup = <int, List<Modifier>>{};
    for (final m in modifiers) {
      final gid = _id(m['category_id']);
      if (gid == null) continue;
      byGroup.putIfAbsent(gid, () => []).add(Modifier(
            id: m['id'] as int,
            groupId: gid,
            name: (m['name'] ?? '') as String,
            price: _num(m['price']),
            priceType: _priceType(m['price_type']),
            sequence: (m['sequence'] ?? 0) as int,
            productId: _id(m['product_id']),
            isDefault: m['is_default'] == true,
          ));
    }

    final mapped = <ModifierGroup>[];
    final byProduct = <int, List<int>>{};
    for (final g in groups) {
      final gid = g['id'] as int;
      mapped.add(ModifierGroup(
        id: gid,
        name: (g['name'] ?? '') as String,
        sequence: (g['sequence'] ?? 0) as int,
        minSelection: (g['min_selection'] ?? 0) as int,
        maxSelection: (g['max_selection'] ?? 0) as int,
        required: g['selection_type'] == 'required',
        autoAdd: g['auto_add'] == true,
        modifiers: byGroup[gid] ?? const [],
      ));
      for (final tmplId in _ids(g['product_template_ids'])) {
        for (final pid in templateToProducts[tmplId] ?? const <int>[]) {
          byProduct.putIfAbsent(pid, () => []).add(gid);
        }
      }
    }
    return _PulledModifiers(mapped, byProduct, model: 'product.modifier.category');
  }

  /// The tenders this till offers: the journals a sale's money can land in.
  ///
  /// The shop's other till reads its payment list straight off `account.journal`,
  /// and this one now does the same, so the two agree on what the shop can be paid
  /// with. A manager narrows it per user on `res.users.payment_method_ids`, and a
  /// user with none named is allowed all of them: that is what the field itself
  /// says, so an empty list widens rather than narrows.
  ///
  /// Two narrowings, each dropped when it would leave nothing, because a till that
  /// can name no tender cannot take money. The branch's company comes first, since
  /// a chain books each branch in a company of its own; a journal that names no
  /// company is unknown rather than disqualified and is kept, for the same reason a
  /// chain's till must not lose a tender it simply cannot see.
  ///
  /// Throws when the journals cannot be read at all, which is the one answer that
  /// means "ask again later" rather than "the shop has none".
  Future<List<PaymentMethod>> _tenders() async {
    // Sequence is asked for as an extra so an Odoo that will not give it still
    // gives up the tenders; without it they come back in the order Odoo listed
    // them, which is the order the other till shows too.
    final rows = await _searchReadOptional(
      'account.journal',
      ['id', 'name', 'type', 'company_id'],
      ['sequence'],
      [
        ['type', 'in', ['bank', 'cash']]
      ],
    );
    var kept = rows;

    final company = companyId();
    if (company != null) {
      final mine = [
        for (final r in kept)
          if (_id(r['company_id']) == null || _id(r['company_id']) == company) r,
      ];
      if (mine.isNotEmpty) kept = mine;
    }

    // The branch's own word sits between the company's and the user's: a shop
    // that filled in `branch.pos.config` named exactly the tenders this branch
    // offers, and the rest of its company's journals stay off the till.
    final named = await _branchNamedJournalIds();
    if (named.isNotEmpty) {
      final mine = [
        for (final r in kept)
          if (named.contains(r['id'])) r,
      ];
      if (mine.isNotEmpty) kept = mine;
    }

    final allowed = await _allowedJournalIds();
    if (allowed.isNotEmpty) {
      final mine = [
        for (final r in kept)
          if (allowed.contains(r['id'])) r,
      ];
      if (mine.isNotEmpty) kept = mine;
    }

    final sorted = [...kept]..sort((a, b) {
        final bySequence =
            ((a['sequence'] as num?) ?? 0).compareTo((b['sequence'] as num?) ?? 0);
        return bySequence != 0
            ? bySequence
            : ((a['name'] ?? '') as String).compareTo((b['name'] ?? '') as String);
      });
    return [
      for (final r in sorted)
        PaymentMethod.journal(
          journalId: r['id'] as int,
          name: (r['name'] ?? '') as String,
          type: (r['type'] ?? '') as String,
        ),
    ];
  }

  /// Whether this Odoo carries `branch.pos.config`, learned by asking once and
  /// held for the life of the puller, for the same reason [_branchFieldMissing]
  /// is: asking an Odoo without the addon on every refresh spends a failing
  /// call each time to learn the same thing.
  bool? _branchConfigMissing;

  /// Whether a failure is Odoo saying it has never heard of the branch POS
  /// configuration model, as opposed to a bad moment on the wire. Matched on
  /// the message because that is all a JSON-RPC fault carries, and the model's
  /// own name has to be in it so an unrelated fault cannot latch the flag.
  static final _unknownConfigModel = RegExp(
      r"branch\.pos\.config[^\n]{0,80}(doesn't exist|does not exist)|"
      r'(object|model|keyerror)[^\n]{0,80}branch\.pos\.config');

  static bool _readsAsMissingConfigModel(Object error) =>
      _unknownConfigModel.hasMatch(error.toString().toLowerCase());

  /// The journals the shop named for this branch on `branch.pos.config`, or
  /// empty for "the shop named none", which callers read as no narrowing.
  ///
  /// The till's branch is a company (jouma books each branch in a company of
  /// its own), so the configuration is found by that company. Errors land here
  /// as empty rather than failing the refresh, unlike the menu's branch filter:
  /// the company narrowing above already keeps other branches' journals off
  /// this till, so the worst a bad moment costs is the branch's own unnamed
  /// journals showing for one refresh. An Odoo that plainly says it has no
  /// such model is remembered so it is not asked again until the next launch.
  Future<Set<int>> _branchNamedJournalIds() async {
    final company = companyId();
    if (company == null || _branchConfigMissing == true) return const {};
    try {
      final rows = await _searchRead(
        'branch.pos.config',
        ['payment_journal_ids'],
        [
          ['company_id', '=', company]
        ],
      );
      _branchConfigMissing = false;
      return {
        for (final r in rows) ..._ids(r['payment_journal_ids']),
      };
    } catch (e) {
      if (_readsAsMissingConfigModel(e)) _branchConfigMissing = true;
      return const {};
    }
  }

  /// The journals this till's Odoo user may take money on, or empty for "nobody
  /// said".
  ///
  /// Empty is never a refusal to sell. The field means every journal when it is left
  /// empty, an Odoo without the field says nothing about who may take what, and a
  /// till that has not authenticated yet has no user to ask about. All three land
  /// here as no narrowing, which is the answer that keeps a till trading.
  Future<Set<int>> _allowedJournalIds() async {
    final uid = userId?.call();
    if (uid == null) return const {};
    try {
      final rows = await _searchReadOptional(
        'res.users',
        ['id'],
        ['payment_method_ids'],
        [
          ['id', '=', uid]
        ],
      );
      if (rows.isEmpty) return const {};
      return _ids(rows.first['payment_method_ids']).toSet();
    } catch (_) {
      return const {};
    }
  }
  /// Partners matching [term] by name or phone, straight from the server.
  ///
  /// The pull above is bounded at 500 partners, which is a menu-sized list and not
  /// a customer book: a shop with more of them cannot find the rest on the till.
  /// This is the way back to them, and it is a read of a standard model through the
  /// same call_kw the catalogue uses, so it needs nothing new on the server.
  ///
  /// Deliberately not on any selling path: it answers a picker, and a caller that
  /// cannot reach the server gets an exception to swallow rather than a wait.
  Future<List<Customer>> searchCustomers(String term, {int limit = 20}) async {
    final q = term.trim();
    if (q.isEmpty) return const [];
    final raw = await call('res.partner', 'search_read', [
      [
        ['customer_rank', '>', 0],
        '|',
        '|',
        ['name', 'ilike', q],
        ['phone', 'ilike', q],
        ['mobile', 'ilike', q],
      ],
      ['id', 'name', 'phone', 'mobile']
    ], {
      'limit': limit,
      'order': 'name'
    });
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .map((c) => Customer(
              id: c['id'] as int,
              name: (c['name'] ?? '') as String,
              phone: c['phone'] is String
                  ? c['phone'] as String
                  : (c['mobile'] is String ? c['mobile'] as String : null),
            ))
        .toList();
  }

  /// Odoo products a manager can link a locally created dish to.
  ///
  /// Narrowed to this till's point of sale wherever the server lets it be: a shop
  /// with one Odoo database and six restaurants in it does not want the other five
  /// menus in the pick list. The narrowing is by the categories that point of sale
  /// is limited to, which is the only per-`pos.config` product scope Odoo has; a
  /// point of sale that is not limited, a restaurant id nobody set, or a server that
  /// will not answer the question all fall back to every product available in the
  /// point of sale, which is the list this would have shown anyway.
  ///
  /// Off every selling path, like [searchCustomers]. A caller that cannot reach the
  /// server gets an exception to show, not a wait.
  Future<List<OdooRef>> searchProducts(String term, {int limit = 30}) async {
    final scope = await _posCategoryScope();
    final q = term.trim();
    final rows = await _searchRead(
      'product.product',
      ['id', 'display_name', 'default_code'],
      [
        ['available_in_pos', '=', true],
        if (scope.isNotEmpty) ['pos_categ_ids', 'in', scope],
        if (q.isNotEmpty) ['name', 'ilike', q],
      ],
    );
    return rows
        .take(limit)
        .map((r) => OdooRef(
              id: r['id'] as int,
              name: (r['display_name'] ?? r['name'] ?? '') as String,
              reference: r['default_code'] is String ? r['default_code'] as String : null,
            ))
        .toList();
  }

  /// Odoo POS categories a manager can link a local category to, narrowed the same
  /// way and degrading the same way.
  Future<List<OdooRef>> searchCategories(String term, {int limit = 30}) async {
    final scope = await _posCategoryScope();
    final q = term.trim();
    final rows = await _searchRead('pos.category', ['id', 'name'], [
      if (scope.isNotEmpty) ['id', 'in', scope],
      if (q.isNotEmpty) ['name', 'ilike', q],
    ]);
    return rows
        .take(limit)
        .map((r) => OdooRef(id: r['id'] as int, name: (r['name'] ?? '') as String))
        .toList();
  }

  /// The POS categories this till's point of sale is limited to, or empty for "no
  /// narrowing is possible", which every failure here answers with.
  Future<List<int>> _posCategoryScope() async {
    final configId = restaurantId();
    if (configId == null) return const [];
    try {
      final configs = await _searchRead(
          'pos.config', ['id', 'limit_categories', 'iface_available_categ_ids'], [
        ['id', '=', configId]
      ]);
      if (configs.isEmpty || configs.first['limit_categories'] != true) {
        return const [];
      }
      return _ids(configs.first['iface_available_categ_ids']);
    } catch (_) {
      // An older point of sale without the field, or a server that refused the
      // read. Either way the shop still gets a pick list.
      return const [];
    }
  }

  /// The branch Odoo says this till's login belongs to, or null when Odoo has
  /// no say: no login authenticated yet, no branch addon on the server, no
  /// branch naming this user, or several of them (a floater's login decides
  /// nothing). Null always means "keep what the till has", never "clear it".
  ///
  /// This is what stops a chain's till sitting on the wrong branch: the shop
  /// lists its people once on the branch record in Odoo, and every till they
  /// sign into adopts that branch on its next sync, whatever was picked by
  /// hand on the device.
  Future<OdooBoundSite?> boundSite() async {
    final uid = userId?.call();
    if (uid == null) return null;
    try {
      final rows = await _searchReadOptional(
        'branch.simple',
        ['id', 'name', 'company_id'],
        ['warehouse_id'],
        [
          ['user_ids', 'in', [uid]]
        ],
      );
      if (rows.length != 1) return null;
      final company = _id(rows.first['company_id']);
      if (company == null) return null;
      return OdooBoundSite(
        name: (rows.first['name'] ?? '') as String,
        companyId: company,
        warehouseId: _id(rows.first['warehouse_id']),
      );
    } catch (_) {
      // No addon, no read rights, or a bad moment on the wire: all of them mean
      // Odoo has no say today, and the till keeps the ids it has.
      return null;
    }
  }

  /// What Odoo has for the three ids that say where this till books: the branches,
  /// the points of sale and the warehouses, each with the name it is known by.
  ///
  /// Nobody knows their warehouse's database id, so the alternative to this is a
  /// manager guessing a number and a till quietly booking into the wrong place.
  ///
  /// Off every selling path, like [searchCustomers] and [searchProducts]: it fills
  /// a picker on a settings screen, and a caller with no line gets empty lists to
  /// fall back from rather than a wait. Each model degrades on its own, because
  /// half a set of names is more use to a manager than none.
  Future<OdooSiteChoices> siteChoices() async => OdooSiteChoices(
        branches: await _siteOptions('res.company'),
        pointsOfSale: await _siteOptions('pos.config', byCompany: true),
        warehouses: await _siteOptions('stock.warehouse', byCompany: true),
      );

  /// One picker's rows. [byCompany] asks for the owning company as an optional
  /// field, so a model that will not give it still gives up its names and the
  /// screen simply narrows nothing.
  Future<List<OdooSiteOption>> _siteOptions(String model,
      {bool byCompany = false}) async {
    try {
      final rows = await _searchReadOptional(model, ['id', 'name'],
          [if (byCompany) 'company_id'], const []);
      return [
        for (final r in rows)
          if (r['id'] is int)
            OdooSiteOption(
              id: r['id'] as int,
              name: (r['name'] ?? '') as String,
              companyId: _id(r['company_id']),
            ),
      ];
    } catch (_) {
      // A model this login may not read leaves its own picker on whatever the till
      // cached, rather than taking the other two down with it.
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> _searchRead(
      String model, List<String> fields, List<dynamic> domain) async {
    final res = await call(model, 'search_read', [domain, fields], {});
    if (res is! List) return const [];
    return res.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  /// A read that also asks for [optional] fields and keeps whichever of them the
  /// server will actually give.
  ///
  /// An add-on older than a flag must still give up its modifiers: losing the whole
  /// menu to gain a default would be a bad trade. Nor may one refused extra take the
  /// others down with it, so when the combined read fails each extra is asked about
  /// on its own and the read is repeated with the survivors. Those probes cost a row
  /// each and only happen on a server that refused something, which is once a pull
  /// and never on the path of a sale.
  Future<List<Map<String, dynamic>>> _searchReadOptional(String model,
      List<String> fields, List<String> optional, List<dynamic> domain) async {
    if (optional.isEmpty) return _searchRead(model, fields, domain);
    try {
      return await _searchRead(model, [...fields, ...optional], domain);
    } catch (_) {
      final allowed = <String>[];
      for (final field in optional) {
        if (await _serves(model, field, domain)) allowed.add(field);
      }
      return _searchRead(model, [...fields, ...allowed], domain);
    }
  }

  /// Whether the server will read [field] on [model] at all, asked with one row so
  /// the question costs nothing on a large catalogue.
  Future<bool> _serves(String model, String field, List<dynamic> domain) async {
    try {
      await call(model, 'search_read', [
        domain,
        ['id', field]
      ], {
        'limit': 1
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Odoo returns a many2one as `[id, label]`, or `false` when unset.
  static int? _id(dynamic v) {
    if (v is int) return v;
    if (v is List && v.isNotEmpty && v.first is int) return v.first as int;
    return null;
  }

  static List<int> _ids(dynamic v) =>
      v is List ? v.whereType<int>().toList() : const [];

  static double _num(dynamic v) => v is num ? v.toDouble() : 0;

  /// Odoo hands a picture over as base64, or as `false` for a product with none.
  /// Anything that will not decode is treated as no picture at all: a broken image
  /// is not worth failing a catalogue refresh over.
  static Uint8List? _image(dynamic v) {
    if (v is! String || v.isEmpty) return null;
    try {
      final bytes = base64Decode(v);
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  static ModifierPriceType _priceType(dynamic v) => switch (v) {
        'percentage' => ModifierPriceType.percentage,
        'free' => ModifierPriceType.free,
        _ => ModifierPriceType.fixed,
      };
}

/// One add-on's answer about modifiers: the groups, which products they hang on,
/// and whether the question was answered at all.
class _PulledModifiers {
  const _PulledModifiers(this.groups, this.productGroupIds,
      {this.read = true, this.model});

  /// Nothing, because the models could not be read. Distinct from an answer of
  /// no groups, which is a fact about the shop rather than about the server.
  static const unread =
      _PulledModifiers(<ModifierGroup>[], <int, List<int>>{}, read: false);

  final List<ModifierGroup> groups;
  final Map<int, List<int>> productGroupIds;
  final bool read;

  /// The Odoo model these groups came out of, or null when none of them answered
  /// with a row. Two add-ons can be installed at once and only one of them is in
  /// use, so this is what a support call needs before anybody edits anything.
  final String? model;
}

/// One Odoo record a manager can point a local menu row at.
class OdooRef {
  const OdooRef({required this.id, required this.name, this.reference});

  final int id;
  final String name;

  /// The internal reference, when the product carries one. Two dishes on a big menu
  /// often read the same in a list; the code is what tells them apart.
  final String? reference;
}

class CataloguePull {
  const CataloguePull({
    required this.categories,
    required this.products,
    required this.groups,
    required this.productGroupIds,
    this.groupsRead = false,
    this.modifierModel,
    this.branchFilterUnavailable = false,
    this.paymentMethods = const [],
    this.paymentMethodsRead = false,
    this.customers = const [],
    this.productImages = const {},
  });

  final List<Category> categories;
  final List<Product> products;
  final List<ModifierGroup> groups;
  final Map<int, List<int>> productGroupIds;

  /// Whether the server actually answered the modifier question. False means no
  /// model it was asked about could be read, and an empty [groups] then says
  /// nothing about the shop: the till keeps the modifiers it already had. The same
  /// distinction [paymentMethodsRead] draws, and for the same reason.
  final bool groupsRead;

  /// The Odoo model the modifier groups came from, null when neither add-on had a
  /// row to give. Two of them can be installed side by side, so support cannot tell
  /// which one a shop is actually editing without being told.
  final String? modifierModel;

  /// Whether this till asked for its branch's menu and had to take the whole one
  /// because the server has no branches field. The menu is right enough to trade on
  /// and wrong enough to explain a chain seeing another shop's dishes, and nothing
  /// said so anywhere before.
  final bool branchFilterUnavailable;

  final List<PaymentMethod> paymentMethods;

  /// Whether the server actually answered the tender question. False means it
  /// refused or was not asked, and an empty [paymentMethods] then says nothing
  /// about the shop: the till keeps the tenders it already had.
  final bool paymentMethodsRead;
  final List<Customer> customers;

  /// The picture bytes for the products that have one, by product id. Empty when
  /// the shop does not show pictures or the server has none, and a product missing
  /// from here simply keeps its coloured tile.
  final Map<int, Uint8List> productImages;

  /// A pull with no products is refused rather than written: replacing a working
  /// catalogue with an empty one would leave the till unable to sell.
  ///
  /// Refusing it is right and hides which of two very different things happened. A
  /// pull that could not finish throws, so a pull that gets this far did reach the
  /// server and was answered: an empty one means this till's branch has nothing
  /// filed against it, which is a job for whoever configures the menu and not for
  /// whoever fixes the network. [SyncService] keeps the two apart on the
  /// diagnostics screen.
  bool get isUsable => products.isNotEmpty;
}
