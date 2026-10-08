import 'package:flutter/material.dart';

import '../../../core/i18n/l10n.dart';
import '../../../domain/catalogue.dart';
import '../../../domain/order.dart';
import '../report_period_dialog.dart';
import 'flash_preview_screen.dart';
import 'flash_report_data.dart';
import 'flash_type_dialog.dart';

/// «انهي فلاش تحتاج؟» → period → (cashier / tender) → the slip. Shared by the
/// reports hub and the floor's Flash report tile.
///
/// [asPopup] shows the slip over the current screen instead of pushing a page, so
/// the floor stays where it is underneath.
Future<void> runFlashFlow(
  BuildContext context, {
  required List<Order> Function(ReportPeriodChoice period) ordersFor,
  required String Function(double) formatAmount,
  Future<void> Function(ReportPeriodChoice period)? prepare,
  DateTime? shiftOpenedAt,
  Map<String, String> staffNames = const {},
  String shopName = '',
  List<Category> categories = const [],
  Set<int> cashTenderIds = const {},
  Future<void> Function(String title, List<(String, String)> rows)? onPrint,
  Future<void> Function(FlashReportData data, FlashKind kind)? onPrintFlash,
  bool asPopup = false,
}) async {
  final kind = await showFlashTypeDialog(context);
  if (!context.mounted || kind == null) return;
  final period = await showReportPeriodDialog(
    context,
    title: tr(context, 'Select period'),
    shiftOpenedAt: shiftOpenedAt,
  );
  if (!context.mounted || period == null) return;
  if (prepare != null) {
    await prepare(period);
    if (!context.mounted) return;
  }
  final shop = ordersFor(period);

  void noSales() => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr(context, 'No sales in this period'))));

  Future<void> show({
    required FlashKind kind,
    required String title,
    required List<Order> orders,
    String? filterLabel,
  }) async {
    final data = FlashReportBuilder.build(
      title: title,
      periodLabel: period.label,
      orders: orders,
      filterLabel: filterLabel,
      cashierName: (id) => staffNames[id] ?? id,
    );
    final preview = FlashPreviewScreen(
      data: data,
      kind: kind,
      shopName: shopName,
      formatAmount: formatAmount,
      categories: categories,
      cashTenderIds: cashTenderIds,
      onPrint: onPrint,
      onPrintFlash: onPrintFlash,
      staffNames: staffNames,
    );
    if (!asPopup) {
      await Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => preview));
      return;
    }
    final size = MediaQuery.of(context).size;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        key: const Key('flash-popup'),
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 560.0.clamp(0.0, size.width - 48),
          height: size.height * 0.85,
          child: preview,
        ),
      ),
    );
  }

  switch (kind) {
    case FlashKind.collector:
    case FlashKind.summary:
      await show(
        kind: kind,
        title:
            kind == FlashKind.collector ? 'Flash Collector' : 'Flash Summary',
        orders: shop,
      );
    case FlashKind.delivery:
      await show(
        kind: kind,
        title: 'Delivery Flash',
        orders: FlashReportBuilder.deliveryOnly(shop),
        filterLabel: tr(context, 'Delivery only'),
      );
    case FlashKind.today:
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(tr(ctx, "Today's Flash")),
          children: [
            SimpleDialogOption(
              key: const Key('flash-today-all'),
              onPressed: () => Navigator.pop(ctx, 'all'),
              child: Text(tr(ctx, 'All cashiers — every till')),
            ),
            SimpleDialogOption(
              key: const Key('flash-today-cashier'),
              onPressed: () => Navigator.pop(ctx, 'cashier'),
              child: Text(tr(ctx, 'By cashier')),
            ),
          ],
        ),
      );
      if (!context.mounted || choice == null) return;
      if (shop.isEmpty) return noSales();
      if (choice == 'all') {
        await show(
          kind: FlashKind.today,
          title: tr(context, "Today's Flash"),
          orders: shop,
        );
        return;
      }
      final ids = FlashReportBuilder.cashierIds(shop);
      if (ids.isEmpty) return noSales();
      final who = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(tr(ctx, 'Cashier')),
          children: [
            for (final id in ids)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, id),
                child: Text(staffNames[id] ?? id),
              ),
          ],
        ),
      );
      if (!context.mounted || who == null) return;
      await show(
        kind: FlashKind.today,
        title: tr(context, "Today's Flash"),
        orders: shop.where((o) => o.cashierId == who).toList(),
        filterLabel: staffNames[who] ?? who,
      );
    case FlashKind.paymentMethod:
      final labels = FlashReportBuilder.paymentLabels(shop);
      if (labels.isEmpty) return noSales();
      final method = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(tr(ctx, 'Payment Method Flash')),
          children: [
            for (final m in labels)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, m),
                child: Text(m),
              ),
          ],
        ),
      );
      if (!context.mounted || method == null) return;
      await show(
        kind: FlashKind.paymentMethod,
        title: '$method Flash',
        orders: FlashReportBuilder.withPayment(shop, method),
        filterLabel: method,
      );
  }
}
