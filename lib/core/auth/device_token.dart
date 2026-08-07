/// A signed, time-boxed authorisation to operate this till.
///
/// The grace period is the whole point: it must outlast the worst realistic outage.
/// An auth or licence check that needs the network to authorise a sale rebuilds the
/// exact problem this app exists to solve.
class DeviceToken {
  const DeviceToken({
    required this.deviceId,
    required this.tenantId,
    required this.issuedAt,
    required this.expiresAt,
    required this.signature,
  });

  final String deviceId;
  final String tenantId;
  final DateTime issuedAt;

  /// Hard stop. After this the till must re-enrol.
  final DateTime expiresAt;

  /// Server signature over the claims. Verified with a public key shipped in the
  /// app; the private key never leaves the server.
  final String signature;

  bool isValidAt(DateTime now) => now.isBefore(expiresAt);

  /// Renew well before expiry so a device that is offline at renewal time still has
  /// a long runway.
  bool shouldRenewAt(DateTime now, {Duration before = const Duration(days: 7)}) =>
      now.isAfter(expiresAt.subtract(before));

  Duration remainingAt(DateTime now) =>
      isValidAt(now) ? expiresAt.difference(now) : Duration.zero;

  Map<String, dynamic> toMap() => {
        'device_id': deviceId,
        'tenant_id': tenantId,
        'issued_at': issuedAt.toIso8601String(),
        'expires_at': expiresAt.toIso8601String(),
        'signature': signature,
      };

  factory DeviceToken.fromMap(Map<String, dynamic> m) => DeviceToken(
        deviceId: m['device_id'] as String,
        tenantId: m['tenant_id'] as String,
        issuedAt: DateTime.parse(m['issued_at'] as String),
        expiresAt: DateTime.parse(m['expires_at'] as String),
        signature: m['signature'] as String,
      );
}
