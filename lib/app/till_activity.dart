/// What the till is doing right now, for anything that has to decide whether this
/// is a safe moment to interrupt it.
///
/// Small and mutable on purpose. The update gate is built in the composition root,
/// before any screen exists, but the only honest answer to "is a sale open" comes
/// from the selling screen. This is the seam between the two, so the gate reads a
/// real answer instead of a default that quietly says no customer is standing
/// there.
class TillActivity {
  /// A cashier has lines on screen or a payment open.
  bool saleInProgress = false;
}
