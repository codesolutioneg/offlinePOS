import 'package:flutter/material.dart';

import '../sell/order_actions.dart';
import '../tables/floor_action_bar.dart';

/// One screen or button a level can be allowed, sent to a manager, or kept from.
/// The label is the English l10n key.
typedef AccessItem = ({String id, String label, IconData icon});

/// A titled group of [AccessItem]s, in the order the levels screen lists them.
typedef AccessGroup = ({String title, IconData icon, List<AccessItem> items});

/// Every screen the till opens from a button, the drawer or a Misc pad.
const List<AccessItem> accessScreens = [
  (id: 'screen.delivery', label: 'Delivery station', icon: Icons.delivery_dining),
  (id: 'screen.tabs', label: 'Open orders', icon: Icons.table_restaurant),
  (id: 'screen.history', label: 'Order history', icon: Icons.receipt_long),
  (id: 'screen.shift', label: 'Shift', icon: Icons.point_of_sale),
  (id: 'screen.reports', label: 'Reports', icon: Icons.bar_chart),
  (id: 'screen.flash', label: 'Flash Report', icon: Icons.flash_on),
  (id: 'screen.kitchen', label: 'Kitchen display', icon: Icons.soup_kitchen),
  (id: 'screen.store-orders', label: 'Store orders', icon: Icons.storefront_outlined),
  (id: 'screen.attendance', label: 'Attendance', icon: Icons.how_to_reg_outlined),
  (id: 'screen.roster', label: 'Staff', icon: Icons.badge_outlined),
  (id: 'screen.settings', label: 'Settings', icon: Icons.settings),
  (id: 'screen.support', label: 'Support & printers', icon: Icons.support_agent),
  (id: 'screen.audit', label: 'View Button Log', icon: Icons.touch_app),
];

/// The floor's Misc pad, by the ids the pad answers with.
const List<AccessItem> floorMiscItems = [
  (id: 'reprint', label: 'Re-print', icon: Icons.print),
  (id: 'revise', label: 'Revise Settlement', icon: Icons.edit_note),
  (id: 'merge', label: 'Merge Tables', icon: Icons.merge_type),
  (id: 'unmerge', label: 'Unmerge Tables', icon: Icons.call_split),
  (id: 'print-all', label: 'Print All', icon: Icons.print_outlined),
  (id: 'end-of-day', label: 'End Of Day', icon: Icons.nightlight_round),
  (id: 'paid-in', label: 'Paid In', icon: Icons.move_to_inbox),
  (id: 'paid-out', label: 'Paid Out', icon: Icons.outbox),
  (id: 'employee-paid-out', label: 'Employee Paid Out', icon: Icons.badge_outlined),
  (id: 'money-drop', label: 'Money Drop', icon: Icons.savings_outlined),
  (id: 'view-checks', label: 'View Checks', icon: Icons.fact_check),
  (id: 'assign-badge', label: 'Assign Badge', icon: Icons.fingerprint),
  (id: 'revenue-report', label: 'Revenues Report', icon: Icons.storefront),
  (id: 'reports', label: 'Reports', icon: Icons.bar_chart),
  (id: 'button-log', label: 'View Button Log', icon: Icons.touch_app),
  (id: 'history', label: 'Order history', icon: Icons.receipt_long),
  (id: 'store-orders', label: 'Store orders', icon: Icons.storefront_outlined),
  (id: 'kitchen', label: 'Kitchen display', icon: Icons.soup_kitchen),
  (id: 'nosale', label: 'No sale (open drawer)', icon: Icons.money_off),
  (id: 'attendance', label: 'Attendance', icon: Icons.how_to_reg_outlined),
  (id: 'settings', label: 'Settings', icon: Icons.settings),
  (id: 'support', label: 'Support & printers', icon: Icons.support_agent),
];

/// The order screen's Misc pad, by the ids the pad answers with.
const List<AccessItem> orderMiscItems = [
  (id: 'print', label: 'Print bill', icon: Icons.receipt_long_outlined),
  (id: 'move-order', label: 'Move the whole order to another table',
      icon: Icons.table_restaurant_outlined),
  (id: 'move', label: 'Transfer Items', icon: Icons.move_down),
  (id: 'merge', label: 'Merge another table in', icon: Icons.merge_type),
  (id: 'split-table', label: 'Split this bill onto another table',
      icon: Icons.call_split),
  (id: 'timing', label: 'Change Course', icon: Icons.restaurant_menu),
  (id: 'resend', label: 'Resend to kitchen', icon: Icons.replay),
  (id: 'employee-transfer', label: 'Employee Transfer', icon: Icons.swap_horiz),
  (id: 'discount-items', label: 'Discount Items', icon: Icons.sell_outlined),
  (id: 'discount-check', label: 'Discount Check', icon: Icons.percent),
  (id: 'split-check', label: 'Split Check', icon: Icons.call_split),
  (id: 'customer-count', label: 'Customer Count', icon: Icons.groups_2_outlined),
  (id: 'hold-on', label: 'Item Hold: on', icon: Icons.pause_circle_outline),
  (id: 'hold-off', label: 'Item Hold: off', icon: Icons.play_circle_outline),
  (id: 'hold-toggle', label: 'Item Hold: toggle', icon: Icons.sync),
  (id: 'item-lookup', label: 'Item Lookup', icon: Icons.manage_search),
  (id: 'stock', label: 'In Stock Quantity', icon: Icons.inventory_2_outlined),
  (id: 'revenue-center', label: 'Revenue Center', icon: Icons.storefront),
  (id: 'customer', label: 'Customer', icon: Icons.person_outline),
  (id: 'driver', label: 'Driver', icon: Icons.two_wheeler),
  (id: 'delivery', label: 'Delivery details', icon: Icons.delivery_dining),
  (id: 'refund', label: 'Refund', icon: Icons.currency_exchange),
];

/// Everything, grouped. Button ids carry the group as a prefix (floor., order.,
/// fmisc., omisc.) so the same word on two pads is two rules.
final List<AccessGroup> accessGroups = [
  (title: 'Screens', icon: Icons.web_asset, items: accessScreens),
  (
    title: 'Floor buttons',
    icon: Icons.table_restaurant,
    items: [
      for (final a in FloorActionBar.catalog)
        (id: 'floor.${a.id}', label: a.label, icon: a.icon),
    ],
  ),
  (
    title: 'Order screen buttons',
    icon: Icons.point_of_sale,
    items: [
      for (final a in orderActionCatalog)
        (id: 'order.${a.id}', label: a.label, icon: a.icon),
    ],
  ),
  (
    title: 'Floor Misc',
    icon: Icons.more_horiz,
    items: [
      for (final a in floorMiscItems)
        (id: 'fmisc.${a.id}', label: a.label, icon: a.icon),
    ],
  ),
  (
    title: 'Order Misc',
    icon: Icons.settings_suggest,
    items: [
      for (final a in orderMiscItems)
        (id: 'omisc.${a.id}', label: a.label, icon: a.icon),
    ],
  ),
];
