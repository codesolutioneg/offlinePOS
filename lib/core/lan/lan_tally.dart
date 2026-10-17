import 'lan_peer.dart';

/// What one till answered when asked which sales it holds: its uuids, or why it
/// could not be asked.
class LanTallyAnswer {
  const LanTallyAnswer.counted(this.peer, Set<String> this.uuids) : error = null;
  const LanTallyAnswer.failed(this.peer, String this.error) : uuids = null;

  final LanPeer peer;
  final Set<String>? uuids;
  final String? error;
}

/// The tills whose sales this one does not hold, one gap per till.
///
/// Catch-up reads each peer to the end of its log and reports the ones it could
/// not reach. That says the reading happened, not that it was complete: a till
/// read through the primary, a page cut short, or an event applied and later lost
/// all leave the closer short without any pull having failed. The tally is the
/// proof the catch-up lacks: every sale a peer rang in the window has to be in
/// [local], by uuid, or the till that rang it is named here.
List<LanTillGap> tallyGaps({
  required Set<String> local,
  required Iterable<LanTallyAnswer> answers,
}) =>
    [
      for (final answer in answers)
        if (answer.error case final error?)
          LanTillGap(
            deviceId: answer.peer.deviceId,
            name: answer.peer.name,
            reason: 'could not list its sales: $error',
            lastSeenAt: answer.peer.lastSeenAt,
          )
        else if (answer.uuids!.difference(local).length case final short
            when short > 0)
          LanTillGap(
            deviceId: answer.peer.deviceId,
            name: answer.peer.name,
            reason: short == 1
                ? '1 sale rung there is not on this till yet'
                : '$short sales rung there are not on this till yet',
            lastSeenAt: answer.peer.lastSeenAt,
          ),
    ];
