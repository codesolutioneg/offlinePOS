import '../../domain/order.dart';
import '../db/stress_purge.dart';

export '../db/stress_purge.dart' show kStressNote;

/// Whether [order] was made by the Stress Lab. A lab order is test data: it is
/// never booked in Odoo and never mirrored to Dishflow, whatever is queued.
bool isStressOrder(Order order) => order.note == kStressNote;

/// The same test on a queued payload, which carries the order's note.
bool isStressPayload(Map<String, dynamic> payload) =>
    payload['note'] == kStressNote;
