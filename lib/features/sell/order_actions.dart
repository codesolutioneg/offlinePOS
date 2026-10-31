import 'package:flutter/material.dart';

/// Every button the order screen's bottom bar can carry, in bar order: id,
/// English l10n label, icon, colour. The order screen builds its tiles from these
/// and settings lists them to switch off.
const List<({String id, String label, IconData icon, Color color})>
    orderActionCatalog = [
  (id: 'delete', label: 'Delete', icon: Icons.delete_forever,
      color: Color(0xFFE53935)),
  (id: 'quantity', label: 'Quantity', icon: Icons.exposure,
      color: Color(0xFFA89A00)),
  (id: 'send', label: 'Send', icon: Icons.send, color: Color(0xFFD35400)),
  (id: 'timed-send', label: 'Timed Send', icon: Icons.timer_outlined,
      color: Color(0xFF7F8C8D)),
  (id: 'print', label: 'Print', icon: Icons.print, color: Color(0xFF1E6B52)),
  (id: 'settle', label: 'Settle', icon: Icons.shopping_cart_checkout,
      color: Color(0xFF27AE60)),
  (id: 'reference', label: 'Reference', icon: Icons.note_alt_outlined,
      color: Color(0xFF5D6D7E)),
  (id: 'misc', label: 'Misc', icon: Icons.settings_suggest,
      color: Color(0xFF8E2447)),
  (id: 'exit', label: 'Exit', icon: Icons.exit_to_app,
      color: Color(0xFF34495E)),
];
