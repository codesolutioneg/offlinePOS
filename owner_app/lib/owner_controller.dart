import 'package:flutter/material.dart';

import 'api.dart';
import 'data_scope.dart';
import 'orders.dart';
import 'owner_period.dart';

/// Shared period / branch / data for the owner shell tabs.
class OwnerController extends ChangeNotifier {
  OwnerController({
    required this.api,
    required this.session,
  }) {
    final branches = session.branches;
    branchId = branches.length == 1 ? branches.single.id : null;
    _applyPreset('today');
  }

  final OwnerApi api;
  OwnerSession session;
  late final data = OwnerData(api);

  /// `today` | `yesterday` | `last7` | `custom`
  String period = 'today';
  DateTime? customFrom;
  DateTime? customTo;
  String? customLabel;
  String? branchId;
  var loading = true;

  OwnerUser get user => session.user;
  List<OwnerBranch> get branches => session.branches;

  PeriodKpis get kpis => computeKpis(data.orders, data.costs);

  /// Exclusive [to] local midnight for the active hub filter.
  (DateTime from, DateTime to) get periodBounds {
    if (period == 'custom' && customFrom != null && customTo != null) {
      return (customFrom!, customTo!);
    }
    return periodWindow(period == 'custom' ? 'today' : period, DateTime.now());
  }

  String periodLabel({required bool arabic}) {
    if (period == 'custom' && customLabel != null) return customLabel!;
    return switch (period) {
      'yesterday' => arabic ? 'أمس' : 'Yesterday',
      'last7' => arabic ? 'آخر 7 أيام' : 'Last 7 days',
      'custom' => arabic ? 'مخصص' : 'Custom',
      _ => arabic ? 'اليوم' : 'Today',
    };
  }

  String branchLabel({required bool arabic}) {
    if (branchId == null) {
      return arabic ? 'كل الفروع' : 'All branches';
    }
    for (final b in branches) {
      if (b.id == branchId) return b.name;
    }
    return branchId!;
  }

  void _applyPreset(String key) {
    period = key;
    customFrom = null;
    customTo = null;
    customLabel = null;
  }

  void applyPeriodChoice(OwnerPeriodChoice choice) {
    period = choice.preset;
    if (choice.preset == 'custom') {
      customFrom = choice.from;
      customTo = choice.to;
      customLabel = choice.label;
    } else {
      customFrom = null;
      customTo = null;
      customLabel = null;
    }
  }

  Future<void> reload() async {
    loading = true;
    notifyListeners();
    final (from, to) = periodBounds;
    await data.load(branchId: branchId, from: from, to: to);
    loading = false;
    notifyListeners();
  }

  void setPeriod(String value) {
    if (period == value && value != 'custom') return;
    _applyPreset(value);
    reload();
  }

  void setCustomRange(DateTimeRange range, {required bool arabic}) {
    applyPeriodChoice(OwnerPeriodChoice.custom(range, arabic: arabic));
    reload();
  }

  void setBranch(String? id) {
    if (branchId == id) return;
    branchId = id;
    reload();
  }

  void updateSession(OwnerSession next) {
    session = next;
    notifyListeners();
  }
}
