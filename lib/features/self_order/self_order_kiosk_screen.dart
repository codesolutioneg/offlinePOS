import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../app/pos_session.dart';
import '../../core/db/catalogue_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/catalogue.dart';
import '../../domain/order.dart';
import '../sell/modifier_sheet.dart';
import 'kiosk_promo.dart';
import 'kiosk_voice.dart';

/// Windows self-order kiosk: phone → touch menu → park unpaid takeaway for the
/// cashier. Kitchen fire happens only after the cashier pays (existing pay path).
///
/// Always paints a light surface: the till's default theme is dark, and inheriting
/// it made cart lines white-on-white.
class SelfOrderKioskScreen extends StatefulWidget {
  const SelfOrderKioskScreen({
    super.key,
    required this.session,
    required this.catalogue,
    required this.formatAmount,
    this.productImages = const {},
    this.shopName = '',
    this.standalone = false,
    this.promoVideoPath,
    this.onPromoVideoChanged,
    this.onPrintTicket,
    this.onStaffExit,
    this.onOpenNetwork,
  });

  final PosSession session;
  final CatalogueStore catalogue;
  final String Function(double) formatAmount;
  final Map<int, Uint8List> productImages;
  final String shopName;

  /// When true this screen is the whole app (dedicated kiosk binary).
  /// Guests cannot leave back into the POS — staff tools are long-press only.
  final bool standalone;
  final String? promoVideoPath;
  final ValueChanged<String?>? onPromoVideoChanged;

  /// Prints a guest ticket / pre-bill for a parked self-order (no kitchen fire).
  final Future<bool> Function(Order order)? onPrintTicket;
  final VoidCallback? onStaffExit;
  final VoidCallback? onOpenNetwork;

  /// Marker on [Order.tableLabel] so open-tabs can filter self-orders.
  static const tableTag = 'SELF-ORDER';

  static bool isSelfOrder(Order o) =>
      o.tableLabel == tableTag ||
      (o.note?.toLowerCase().contains('self-order') ?? false);

  @override
  State<SelfOrderKioskScreen> createState() => _SelfOrderKioskScreenState();
}

enum _KioskStep { phone, menu, done }

class _SelfOrderKioskScreenState extends State<SelfOrderKioskScreen> {
  _KioskStep _step = _KioskStep.phone;
  final _phone = TextEditingController();
  int? _categoryId;
  String? _placedNo;
  String? _placedPhone;
  Order? _placedOrder;
  var _printing = false;
  String? _promoPath;
  var _promoReady = false;

  PosSession get s => widget.session;

  static const _ink = AppColors.textPrimaryLight;
  static const _muted = AppColors.textSecondaryLight;

  @override
  void initState() {
    super.initState();
    s.startFresh(OrderType.takeaway);
    unawaited(_loadPromo());
    WidgetsBinding.instance
        .addPostFrameCallback((_) => KioskVoice.welcome());
  }

  Future<void> _loadPromo() async {
    final path = await KioskPromo.resolvePlayablePath(
        widget.promoVideoPath ?? _promoPath);
    if (!mounted) return;
    setState(() {
      _promoPath = path;
      _promoReady = true;
    });
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  /// Same rail rule as the POS sell screen: stocked categories plus parents.
  List<({int id, String name})> get _categories {
    final rail = s.catalogue.categoryIdsForMenuRail();
    return s.catalogue
        .categories()
        .where((c) => rail.contains(c.id))
        .map((c) => (id: c.id, name: c.name))
        .toList();
  }

  List<Product> get _products {
    final cats = _categories;
    if (cats.isEmpty) return s.catalogue.products(limit: 10000);
    final id = _categoryId ?? cats.first.id;
    if (_categoryId == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _categoryId = id);
      });
    }
    // Parent category → every product filed on it or any child (POS menu tree).
    final tree = s.catalogue.expandCategoryAllowList([id]);
    return s.catalogue
        .products(limit: 10000)
        .where((p) => p.categoryId != null && tree.contains(p.categoryId))
        .toList();
  }

  /// Line total guests pay (net + modifiers + VAT), matching the bag total.
  double _linePay(OrderLine l) {
    final net = l.total;
    if (l.taxRate <= 0) return net;
    return net * (1 + l.taxRate / 100);
  }

  String _lineDetail(OrderLine l) {
    final qty = l.quantity % 1 == 0 ? '${l.quantity.toInt()}' : '${l.quantity}';
    final unit = widget.formatAmount(l.unitPrice);
    final parts = <String>[
      '$qty × $unit',
      for (final m in l.modifiers)
        m.quantity > 1
            ? '+ ${m.name} ×${m.quantity.toStringAsFixed(0)}'
            : '+ ${m.name}',
      if (l.note != null && l.note!.trim().isNotEmpty) l.note!.trim(),
    ];
    return parts.join('\n');
  }

  void _bumpQty(OrderLine l, double delta) {
    final next = l.quantity + delta;
    setState(() => s.setQuantity(l.uuid, next));
  }

  Future<void> _tapProduct(Product product) async {
    if (product.soldByWeight) {
      // Kiosk skips weighed items for now — staff rings those at the till.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(context, 'Ask the cashier for weighed items'))));
      return;
    }
    final groups = s.catalogue.modifierGroupsFor(product.id);
    if (groups.isEmpty) {
      setState(() => s.addProduct(product));
      return;
    }
    if (groups.every((g) => g.resolvesItself)) {
      setState(() => s.addProduct(product, chosen: [
            for (final g in groups)
              for (final m in g.defaults) ChosenModifier(m),
          ]));
      return;
    }
    final chosen = await showModalBottomSheet<List<ChosenModifier>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: ModifierSheet(
          product: product,
          groups: groups,
          formatAmount: widget.formatAmount,
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() => s.addProduct(product, chosen: chosen));
  }

  void _continueFromPhone() {
    final phone = _phone.text.trim();
    if (phone.length < 7) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(context, 'Enter a valid phone number'))));
      return;
    }
    KioskVoice.startNow();
    setState(() => _step = _KioskStep.menu);
  }

  Future<void> _placeOrder() async {
    if (!s.hasLines) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'Add items to your order'))));
      return;
    }
    final phone = _phone.text.trim();
    final order = s.current;
    order.customerPhone = phone;
    order.customerName = phone;
    order.note = 'self-order';
    order.type = OrderType.takeaway;
    s.hold(table: SelfOrderKioskScreen.tableTag);
    final no = order.displayNo;
    final parked = order;
    setState(() {
      _placedNo = no;
      _placedPhone = phone;
      _placedOrder = parked;
      _step = _KioskStep.done;
    });
    KioskVoice.orderConfirmed();
    if (widget.onPrintTicket != null) {
      unawaited(_printTicket(silent: true));
    }
  }

  Future<void> _printTicket({bool silent = false}) async {
    final order = _placedOrder;
    final print = widget.onPrintTicket;
    if (order == null || print == null || _printing) return;
    setState(() => _printing = true);
    final ok = await print(order);
    if (!mounted) return;
    setState(() => _printing = false);
    if (silent) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(tr(
          context, ok ? 'Ticket printed' : 'Bill did not print')),
    ));
  }

  void _nextGuest() {
    _phone.clear();
    s.startFresh(OrderType.takeaway);
    setState(() {
      _placedNo = null;
      _placedPhone = null;
      _placedOrder = null;
      _step = _KioskStep.phone;
      _categoryId = null;
    });
    KioskVoice.welcome();
  }

  Future<void> _pickPromoVideo() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'video',
          extensions: ['mp4', 'mov', 'mkv', 'webm', 'avi'],
        ),
      ],
    );
    if (file == null || !mounted) return;
    setState(() {
      _promoPath = file.path;
      _promoReady = true;
    });
    widget.onPromoVideoChanged?.call(file.path);
  }

  void _clearPromoVideo() {
    widget.onPromoVideoChanged?.call(null);
    setState(() {
      _promoPath = null;
      _promoReady = false;
    });
    unawaited(_loadPromo());
  }

  Future<void> _promoMenu() async {
    final has = _promoPath != null && _promoPath!.isNotEmpty;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: Text(tr(ctx, 'Choose promo video')),
              onTap: () {
                Navigator.pop(ctx);
                _pickPromoVideo();
              },
            ),
            if (has)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(tr(ctx, 'Remove promo video')),
                onTap: () {
                  Navigator.pop(ctx);
                  _clearPromoVideo();
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _exit() async {
    if (s.hasLines) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr(ctx, 'Leave self-order?')),
          content: Text(tr(ctx, 'The items on screen will be discarded.')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr(ctx, 'Stay'))),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr(ctx, 'Leave'))),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      s.current.lines.clear();
      s.orders.save(s.current);
    }
    if (!mounted) return;
    if (widget.onStaffExit != null) {
      widget.onStaffExit!();
      return;
    }
    if (widget.standalone) return;
    Navigator.of(context).pop();
  }

  ThemeData get _kioskTheme => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          brightness: Brightness.light,
          primary: AppColors.primary,
          onPrimary: Colors.white,
          surface: Colors.white,
          onSurface: _ink,
          onSurfaceVariant: _muted,
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F6F8),
        listTileTheme: const ListTileThemeData(
          textColor: _ink,
          iconColor: _ink,
          subtitleTextStyle: TextStyle(color: _muted, height: 1.35),
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: _ink),
          bodyMedium: TextStyle(color: _ink),
          bodySmall: TextStyle(color: _muted),
          titleMedium: TextStyle(color: _ink, fontWeight: FontWeight.w600),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _kioskTheme,
      child: Scaffold(
        backgroundColor: const Color(0xFFF4F6F8),
        body: SafeArea(
          child: switch (_step) {
            _KioskStep.phone => _phoneStep(),
            _KioskStep.menu => _menuStep(),
            _KioskStep.done => _doneStep(),
          },
        ),
      ),
    );
  }

  Future<void> _staffTools() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(tr(ctx, 'Staff tools'),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            if (widget.onPromoVideoChanged != null)
              ListTile(
                leading: const Icon(Icons.movie_outlined),
                title: Text(tr(ctx, 'Promo video')),
                onTap: () {
                  Navigator.pop(ctx);
                  _promoMenu();
                },
              ),
            if (widget.onOpenNetwork != null)
              ListTile(
                leading: const Icon(Icons.lan_outlined),
                title: Text(tr(ctx, 'Shop network')),
                onTap: () {
                  Navigator.pop(ctx);
                  widget.onOpenNetwork!();
                },
              ),
            if (!widget.standalone)
              ListTile(
                key: const Key('self-order-exit'),
                leading: const Icon(Icons.logout),
                title: Text(tr(ctx, 'Staff exit')),
                onTap: () {
                  Navigator.pop(ctx);
                  _exit();
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _header({required String title, VoidCallback? onBack}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              key: const Key('self-order-back'),
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back, color: _ink),
            ),
          Expanded(
            child: GestureDetector(
              onLongPress: _staffTools,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.shopName.isNotEmpty)
                    Text(widget.shopName,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _muted)),
                  Text(title,
                      style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: AppColors.brandNavy)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _promoHeader({
    double height = 220,
    /// Shift the crop downward so the subject sits clearer in frame.
    Alignment alignment = const Alignment(0, 0.45),
  }) {
    final hasVideo =
        _promoReady && _promoPath != null && File(_promoPath!).existsSync();
    return SizedBox(
      height: height,
      width: double.infinity,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasVideo)
              _KioskPromoVideo(
                path: _promoPath!,
                key: ValueKey('$_promoPath|$alignment'),
                alignment: alignment,
              )
            else
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF0F172A),
                      Color(0xFF1B2838),
                      Color(0xFF0EA5E9),
                    ],
                  ),
                ),
              ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x220F172A),
                    Color(0x140F172A),
                    Color(0x990F172A),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _phoneStep() {
    final shop = widget.shopName.trim();
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF0F172A),
            Color(0xFFF1F5F9),
            Color(0xFFF8FAFC),
          ],
          stops: [0.0, 0.42, 1.0],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 5,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _promoHeader(height: double.infinity),
                Positioned(
                  left: 20,
                  right: 20,
                  top: 12,
                  child: _header(title: tr(context, 'Self-order')),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Container(
                      height: 120,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x000F172A),
                            Color(0xE6F1F5F9),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 4,
            child: Transform.translate(
              offset: const Offset(0, -36),
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Material(
                      color: Colors.white,
                      elevation: 18,
                      shadowColor: const Color(0x661B2838),
                      borderRadius: BorderRadius.circular(28),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(
                              color: AppColors.primary.withValues(alpha: 0.22),
                              width: 1.5),
                        ),
                        padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                color: AppColors.primary.withValues(alpha: 0.12),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.smartphone_rounded,
                                  size: 32, color: AppColors.primary),
                            ),
                            const SizedBox(height: 16),
                            if (shop.isNotEmpty) ...[
                              Text(
                                shop,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.6,
                                  color: AppColors.primaryDark,
                                ),
                              ),
                              const SizedBox(height: 6),
                            ],
                            Text(
                              tr(context, 'Enter your phone number to start'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                height: 1.25,
                                color: AppColors.brandNavy,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              tr(context,
                                  'We use it to find your order at the cashier'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 14,
                                height: 1.35,
                                color: _muted,
                              ),
                            ),
                            const SizedBox(height: 22),
                            TextField(
                              key: const Key('self-order-phone'),
                              controller: _phone,
                              keyboardType: TextInputType.phone,
                              autofocus: true,
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                    RegExp(r'[0-9+\s-]')),
                              ],
                              style: const TextStyle(
                                fontSize: 30,
                                letterSpacing: 1.4,
                                color: AppColors.brandNavy,
                                fontWeight: FontWeight.w700,
                              ),
                              textAlign: TextAlign.center,
                              cursorColor: AppColors.primary,
                              decoration: InputDecoration(
                                hintText: '01xxxxxxxxx',
                                hintStyle: TextStyle(
                                    color: _muted.withValues(alpha: 0.65)),
                                filled: true,
                                fillColor: const Color(0xFFF0F9FF),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                  borderSide: BorderSide(
                                      color: AppColors.primary
                                          .withValues(alpha: 0.35),
                                      width: 1.5),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                  borderSide: const BorderSide(
                                      color: AppColors.primary, width: 2),
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 24, vertical: 20),
                              ),
                              onSubmitted: (_) => _continueFromPhone(),
                            ),
                            const SizedBox(height: 18),
                            SizedBox(
                              width: double.infinity,
                              height: 58,
                              child: FilledButton(
                                key: const Key('self-order-phone-next'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.primary,
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16)),
                                ),
                                onPressed: _continueFromPhone,
                                child: Text(tr(context, 'Start ordering'),
                                    style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w800)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _menuStep() {
    final cats = _categories;
    final products = _products;
    final marks = s.catalogue.modifierMarks();
    final total = s.current.total;
    final qty = s.current.lines.fold<double>(0, (n, l) => n + l.quantity);

    return Column(
      children: [
        _promoHeader(height: 180, alignment: const Alignment(0, 0.55)),
        _header(
          title: tr(context, 'Choose your food'),
          onBack: () => setState(() => _step = _KioskStep.phone),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 120,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 8, 12),
                  children: [
                    for (final c in cats)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Material(
                          color: (_categoryId ?? cats.first.id) == c.id
                              ? AppColors.brandNavy
                              : Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          child: InkWell(
                            key: Key('self-order-cat-${c.id}'),
                            borderRadius: BorderRadius.circular(14),
                            onTap: () => setState(() => _categoryId = c.id),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 16, horizontal: 8),
                              child: Text(
                                c.name,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                  color: (_categoryId ?? cats.first.id) == c.id
                                      ? Colors.white
                                      : AppColors.brandNavy,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 0, 16, 16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 200,
                    childAspectRatio: 0.82,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                  ),
                  itemCount: products.length,
                  itemBuilder: (_, i) {
                    final p = products[i];
                    final img = widget.productImages[p.id];
                    final hasMods = marks[p.id] != null;
                    return Material(
                      color: Colors.white,
                      elevation: 1,
                      shadowColor: AppColors.brandNavy.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        key: Key('self-order-product-${p.id}'),
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => _tapProduct(p),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: img != null
                                      ? Image.memory(img, fit: BoxFit.cover)
                                      : ColoredBox(
                                          color: AppColors.surfaceLight,
                                          child: Icon(Icons.fastfood,
                                              size: 40,
                                              color: AppColors.primary
                                                  .withValues(alpha: 0.7)),
                                        ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(p.displayName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14,
                                      color: AppColors.brandNavy)),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Text(widget.formatAmount(p.price),
                                      style: const TextStyle(
                                          color: Color(0xFFDC2626),
                                          fontWeight: FontWeight.w800)),
                                  if (hasMods) ...[
                                    const Spacer(),
                                    const Icon(Icons.tune,
                                        size: 14, color: _muted),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              SizedBox(
                width: 320,
                child: _cartPanel(total: total, qty: qty),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _cartPanel({required double total, required double qty}) {
    final lines = s.current.lines;
    final order = s.current;
    final subtotal = order.subtotal;
    final tax = order.taxTotal;
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(left: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(tr(context, 'Your order'),
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppColors.brandNavy)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_phone.text.trim(),
                style: const TextStyle(color: _muted)),
          ),
          const Divider(height: 24, color: Color(0xFFE2E8F0)),
          Expanded(
            child: lines.isEmpty
                ? Center(
                    child: Text(tr(context, 'Tap items to add them'),
                        style: const TextStyle(color: _muted)))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    itemCount: lines.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, color: Color(0xFFF1F5F9)),
                    itemBuilder: (_, i) {
                      final l = lines[i];
                      final qtyLabel = l.quantity % 1 == 0
                          ? '${l.quantity.toInt()}'
                          : '${l.quantity}';
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(l.name,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.brandNavy,
                                          fontSize: 15)),
                                ),
                                Text(
                                  widget.formatAmount(_linePay(l)),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.brandNavy,
                                      fontSize: 15),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _lineDetail(l),
                              style: const TextStyle(
                                  color: _muted, height: 1.35, fontSize: 13),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                _qtyBtn(
                                  key: Key('self-order-qty-minus-${l.uuid}'),
                                  icon: Icons.remove,
                                  onPressed: () => _bumpQty(l, -1),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12),
                                  child: Text(
                                    qtyLabel,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.brandNavy,
                                    ),
                                  ),
                                ),
                                _qtyBtn(
                                  key: Key('self-order-qty-plus-${l.uuid}'),
                                  icon: Icons.add,
                                  onPressed: () => _bumpQty(l, 1),
                                ),
                                const Spacer(),
                                IconButton(
                                  tooltip: tr(context, 'Remove'),
                                  icon: const Icon(Icons.delete_outline,
                                      color: Color(0xFFDC2626)),
                                  onPressed: () => setState(
                                      () => s.removeLine(l.uuid)),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            color: AppColors.brandNavy,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _moneyRow(tr(context, 'Subtotal'), subtotal,
                    muted: true),
                if (tax > 0.004) ...[
                  const SizedBox(height: 4),
                  _moneyRow(tr(context, 'Tax'), tax, muted: true),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.shopping_bag_outlined,
                        color: Colors.white.withValues(alpha: 0.9)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${qty % 1 == 0 ? qty.toInt() : qty} · ${tr(context, 'Total')}',
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.95),
                            fontSize: 15,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(
                      widget.formatAmount(total),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w900),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 52,
                  child: FilledButton(
                    key: const Key('self-order-place'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _placeOrder,
                    child: Text(tr(context, 'Place order'),
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w800)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _moneyRow(String label, double amount, {bool muted = false}) {
    final color = muted
        ? Colors.white.withValues(alpha: 0.75)
        : Colors.white;
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: TextStyle(
                  color: color, fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        Text(widget.formatAmount(amount),
            style: TextStyle(
                color: color, fontSize: 13, fontWeight: FontWeight.w700)),
      ],
    );
  }

  Widget _qtyBtn({
    required Key key,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: const Color(0xFFF1F5F9),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(10),
        onTap: onPressed,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(icon, size: 20, color: AppColors.brandNavy),
        ),
      ),
    );
  }

  Widget _doneStep() {
    return Column(
      children: [
        _header(title: tr(context, 'Order placed')),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.check_circle,
                        size: 72, color: AppColors.success),
                    const SizedBox(height: 20),
                    Text(tr(context, 'Your order number'),
                        style: const TextStyle(fontSize: 20, color: _muted)),
                    const SizedBox(height: 12),
                    Text(
                      _placedNo ?? '—',
                      key: const Key('self-order-number'),
                      style: const TextStyle(
                        fontSize: 72,
                        fontWeight: FontWeight.w900,
                        color: AppColors.brandNavy,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      tr(context,
                          'Please pay at the cashier with this number. The kitchen starts after payment.'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 16, height: 1.4, color: _ink),
                    ),
                    if (_placedPhone != null) ...[
                      const SizedBox(height: 8),
                      Text(_placedPhone!,
                          style: const TextStyle(color: _muted)),
                    ],
                    const SizedBox(height: 28),
                    if (widget.onPrintTicket != null) ...[
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: OutlinedButton.icon(
                          key: const Key('self-order-print'),
                          onPressed: _printing ? null : () => _printTicket(),
                          icon: _printing
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Icon(Icons.print_outlined),
                          label: Text(
                            tr(context,
                                _printing ? 'Printing…' : 'Print ticket'),
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: FilledButton(
                        key: const Key('self-order-next-guest'),
                        onPressed: _nextGuest,
                        child: Text(tr(context, 'New order'),
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Looping promo clip for the marketing header (file path from [KioskPromo]).
class _KioskPromoVideo extends StatefulWidget {
  const _KioskPromoVideo({
    super.key,
    required this.path,
    this.alignment = Alignment.center,
  });

  final String path;
  final Alignment alignment;

  @override
  State<_KioskPromoVideo> createState() => _KioskPromoVideoState();
}

class _KioskPromoVideoState extends State<_KioskPromoVideo> {
  VideoPlayerController? _controller;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    final c = VideoPlayerController.file(File(widget.path));
    try {
      await c.initialize();
      await c.setLooping(true);
      await c.setVolume(0);
      await c.play();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
    } catch (_) {
      await c.dispose();
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (_failed || c == null || !c.value.isInitialized) {
      return const ColoredBox(color: Color(0xFF0F172A));
    }
    return ColoredBox(
      color: Colors.black,
      child: FittedBox(
        fit: BoxFit.cover,
        alignment: widget.alignment,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: c.value.size.width,
          height: c.value.size.height,
          child: VideoPlayer(c),
        ),
      ),
    );
  }
}
