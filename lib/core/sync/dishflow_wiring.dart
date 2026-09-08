import '../db/settings_store.dart';
import 'dishflow_firestore_sender.dart';
import 'dishflow_mirror.dart';
import 'outbox.dart';

/// Registers the Dishflow owner-mirror sender on the outbox when configured.
///
/// Selling never waits on this. Configure / disable as settings change.
class DishflowWiring {
  DishflowWiring({
    required Outbox outbox,
    DishflowFirestoreSender? sender,
  })  : _outbox = outbox,
        _sender = sender ?? DishflowFirestoreSender();

  final Outbox _outbox;
  final DishflowFirestoreSender _sender;

  DishflowFirestoreSender get sender => _sender;

  bool get isRegistered => _outbox.hasSenderFor(DishflowMirror.kind);

  /// Point the outbox at Dishflow when the mirror is ready; otherwise unregister
  /// so a switched-off setting stops draining without deleting queued rows.
  void apply(SettingsStore settings) {
    if (settings.dishflowMirrorReady) {
      _outbox.register(DishflowMirror.kind, _sender.call);
    } else {
      _outbox.unregister(DishflowMirror.kind);
    }
  }
}
