import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api.dart';
import '../data_scope.dart';
import '../orders.dart';
import '../owner_period.dart';
import '../screens/flash_preview_screen.dart';
import '../widgets/dishflow_loader.dart';
import 'flash_kind.dart';
import 'flash_report_data.dart';

/// «انهي فلاش تحتاج؟» → period (incl. custom dates) → filters → slip.
Future<void> runOwnerFlashFlow(
  BuildContext context, {
  required OwnerApi api,
  required String? branchId,
  required String shopName,
  required bool arabic,
  List<OwnerOrder>? fallbackOrders,
  String? fallbackPeriodLabel,
}) async {
  final kind = await showFlashTypeDialog(context, arabic: arabic);
  if (!context.mounted || kind == null) return;

  final period = await showOwnerPeriodDialog(
    context,
    arabic: arabic,
    title: arabic ? 'فترة الفلاش' : 'Flash period',
  );
  if (!context.mounted || period == null) return;

  void noSales() {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        arabic ? 'لا مبيعات في هذه الفترة' : 'No sales in this period',
        style: GoogleFonts.cairo(),
      ),
    ));
  }

  showDishflowLoadingDialog(context);

  List<OwnerOrder> orders;
  try {
    final data = OwnerData(api);
    await data.load(branchId: branchId, from: period.from, to: period.to);
    orders = data.completed;
  } catch (_) {
    orders = fallbackOrders ?? const [];
  } finally {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }
  if (!context.mounted) return;

  final periodLabel = period.label;

  Future<void> show({
    required FlashKind kind,
    required String title,
    required List<OwnerOrder> list,
    String? filterLabel,
  }) async {
    final data = FlashReportBuilder.build(
      title: title,
      periodLabel: periodLabel,
      orders: list,
      filterLabel: filterLabel,
    );
    if (!context.mounted) return;
    if (data.orders.isEmpty) return noSales();
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FlashPreviewScreen(
        data: data,
        kind: kind,
        shopName: shopName,
        arabic: arabic,
      ),
    ));
  }

  switch (kind) {
    case FlashKind.collector:
    case FlashKind.summary:
      await show(
        kind: kind,
        title: kind == FlashKind.collector
            ? 'Flash Collector'
            : 'Flash Summary',
        list: orders,
      );
    case FlashKind.delivery:
      await show(
        kind: kind,
        title: 'Delivery Flash',
        list: FlashReportBuilder.deliveryOnly(orders),
        filterLabel: arabic ? 'توصيل فقط' : 'Delivery only',
      );
    case FlashKind.today:
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(arabic ? 'فلاش اليوم' : "Today's Flash",
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800)),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'all'),
              child: Text(
                  arabic
                      ? 'كل الكاشير — كل الأجهزة'
                      : 'All cashiers — every till',
                  style: GoogleFonts.cairo()),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'cashier'),
              child: Text(arabic ? 'حسب الكاشير' : 'By cashier',
                  style: GoogleFonts.cairo()),
            ),
          ],
        ),
      );
      if (!context.mounted || choice == null) return;
      final cleaned = salesForReports(orders);
      if (cleaned.isEmpty) return noSales();
      if (choice == 'all') {
        await show(
          kind: FlashKind.today,
          title: arabic ? 'فلاش اليوم' : "Today's Flash",
          list: orders,
        );
        return;
      }
      final ids = FlashReportBuilder.cashierIds(cleaned);
      if (ids.isEmpty) return noSales();
      final who = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(arabic ? 'الكاشير' : 'Cashier',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800)),
          children: [
            for (final id in ids)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, id),
                child: Text(id, style: GoogleFonts.cairo()),
              ),
          ],
        ),
      );
      if (!context.mounted || who == null) return;
      await show(
        kind: FlashKind.today,
        title: arabic ? 'فلاش اليوم' : "Today's Flash",
        list: orders.where((o) => o.cashierId == who).toList(),
        filterLabel: who,
      );
    case FlashKind.paymentMethod:
      final cleaned = salesForReports(orders);
      final labels = FlashReportBuilder.paymentLabels(cleaned);
      if (labels.isEmpty) return noSales();
      final method = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(
              arabic ? 'فلاش طريقة الدفع' : 'Payment Method Flash',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800)),
          children: [
            for (final m in labels)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, m),
                child: Text(m, style: GoogleFonts.cairo()),
              ),
          ],
        ),
      );
      if (!context.mounted || method == null) return;
      await show(
        kind: FlashKind.paymentMethod,
        title: '$method Flash',
        list: FlashReportBuilder.withPayment(orders, method),
        filterLabel: method,
      );
  }
}
