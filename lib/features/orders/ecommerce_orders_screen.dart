import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/pos_session.dart';
import '../../core/db/catalogue_store.dart';
import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/sync/ecommerce_order_mapper.dart';
import '../../core/sync/ecommerce_orders_client.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/feedback.dart';
import '../../domain/ecommerce_order.dart';

/// Incoming Dishflow store (ecommerce) orders for this branch.
///
/// Polls Firebase REST; claim loads the bag onto the till like Dishflow POS.
class EcommerceOrdersScreen extends StatefulWidget {
  const EcommerceOrdersScreen({
    super.key,
    required this.settings,
    required this.session,
    required this.catalogue,
    required this.formatAmount,
    this.cashierName,
    this.onOpened,
  });

  final SettingsStore settings;
  final PosSession session;
  final CatalogueStore catalogue;
  final String Function(double) formatAmount;
  final String? cashierName;
  final VoidCallback? onOpened;

  @override
  State<EcommerceOrdersScreen> createState() => _EcommerceOrdersScreenState();
}

class _EcommerceOrdersScreenState extends State<EcommerceOrdersScreen> {
  final _client = EcommerceOrdersClient();
  List<EcommerceOrder> _orders = const [];
  String? _error;
  bool _loading = true;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _poll = Timer.periodic(const Duration(seconds: 12), (_) {
      if (mounted) unawaited(_refresh(silent: true));
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    final s = widget.settings;
    if (!s.dishflowMirrorReady) {
      setState(() {
        _loading = false;
        _error = tr(context, 'Turn on Dishflow mirror in Settings first.');
        _orders = const [];
      });
      return;
    }
    if (!silent) setState(() => _loading = true);
    try {
      final list = await _client.listActive(
        projectId: s.dishflowProjectId!,
        apiKey: s.dishflowApiKey!,
        branchId: s.dishflowBranchId,
      );
      if (!mounted) return;
      setState(() {
        _orders = list;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _claim(EcommerceOrder order) async {
    final s = widget.settings;
    final cashierId = widget.session.cashierId;
    final ok = await _client.tryClaim(
      projectId: s.dishflowProjectId!,
      apiKey: s.dishflowApiKey!,
      orderId: order.id,
      cashierId: cashierId,
      cashierName: widget.cashierName,
    );
    if (!mounted) return;
    if (!ok) {
      showToast(context, tr(context, 'Could not claim this order'),
          kind: ToastKind.error);
      await _refresh();
      return;
    }
    EcommerceOrderMapper.applyToSession(
      session: widget.session,
      catalogue: widget.catalogue,
      order: order,
    );
    widget.onOpened?.call();
    if (!mounted) return;
    Navigator.of(context).pop('opened');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('ecommerce-orders-screen'),
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        title: Text(tr(context, 'Store orders')),
        actions: [
          IconButton(
            key: const Key('ecommerce-orders-refresh'),
            tooltip: tr(context, 'Refresh'),
            onPressed: () => unawaited(_refresh()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading && _orders.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _orders.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : _orders.isEmpty
                  ? Center(
                      child: Text(
                        tr(context, 'No store orders waiting'),
                        style: const TextStyle(color: AppColors.textMutedLight),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _refresh,
                      child: LayoutBuilder(
                        builder: (ctx, constraints) {
                          const gap = 12.0;
                          const minCard = 180.0;
                          final cols = ((constraints.maxWidth + gap) /
                                  (minCard + gap))
                              .floor()
                              .clamp(2, 5);
                          return GridView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: cols,
                              mainAxisSpacing: gap,
                              crossAxisSpacing: gap,
                              childAspectRatio: 0.82,
                            ),
                            itemCount: _orders.length,
                            itemBuilder: (ctx, i) => _OrderCard(
                              order: _orders[i],
                              formatAmount: widget.formatAmount,
                              onTap: () => unawaited(_claim(_orders[i])),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}

/// Compact tile — same density as [DeliveryWaitingScreen] parked cards.
class _OrderCard extends StatelessWidget {
  const _OrderCard({
    required this.order,
    required this.formatAmount,
    required this.onTap,
  });

  final EcommerceOrder order;
  final String Function(double) formatAmount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final o = order;
    final pending = o.isPending;
    final statusColor = pending ? AppColors.warning : AppColors.primary;
    final statusLabel =
        pending ? tr(context, 'New') : tr(context, 'Received');
    final itemsPreview = o.items
        .take(2)
        .map((i) =>
            '${i.quantity % 1 == 0 ? i.quantity.toInt() : i.quantity}× ${i.name}')
        .join(' · ');
    final more = o.items.length > 2 ? ' +${o.items.length - 2}' : '';
    final subtitle = [
      if (o.customerPhone != null) o.customerPhone!,
      if (o.deliveryAddress != null && o.deliveryAddress!.trim().isNotEmpty)
        o.deliveryAddress!,
    ].join('  ·  ');

    return Material(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      child: InkWell(
        key: Key('ecommerce-order-${o.id}'),
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      o.isDelivery
                          ? Icons.delivery_dining
                          : Icons.shopping_bag_outlined,
                      color: AppColors.primary,
                      size: 22,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    formatAmount(o.customerTotal),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: AppColors.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      o.orderNumber != null
                          ? '#${o.orderNumber}'
                          : (o.customerName ?? o.id),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: AppColors.brandNavy,
                      ),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      statusLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: statusColor,
                      ),
                    ),
                  ),
                ],
              ),
              if (o.customerName != null && o.orderNumber != null) ...[
                const SizedBox(height: 4),
                Text(
                  o.customerName!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: AppColors.brandNavy,
                  ),
                ),
              ],
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textMutedLight,
                    height: 1.25,
                  ),
                ),
              ],
              if (itemsPreview.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '$itemsPreview$more',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.brandNavy,
                  ),
                ),
              ],
              const Spacer(),
              Text(
                tr(context, 'Tap to claim'),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
