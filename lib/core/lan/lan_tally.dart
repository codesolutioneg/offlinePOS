import 'dart:io';

import 'lan_peer.dart';

/// What one till answered when asked which sales it holds: its uuids, or why it
/// could not be asked.
class LanTallyAnswer {
  const LanTallyAnswer.counted(this.peer, Set<String> this.uuids)
      : error = null,
        outdated = false;
  const LanTallyAnswer.failed(this.peer, String this.error)
      : uuids = null,
        outdated = false;

  /// [peer] runs a build from before the tally and does not know the request.
  const LanTallyAnswer.outdated(this.peer)
      : uuids = null,
        error = null,
        outdated = true;

  /// The answer for a request to [peer] that threw [error]. An older build
  /// answers 404 for a path it does not know.
  factory LanTallyAnswer.fromError(LanPeer peer, Object error) =>
      error is HttpException && error.message.startsWith('404 ')
          ? LanTallyAnswer.outdated(peer)
          : LanTallyAnswer.failed(peer, '$error');

  final LanPeer peer;
  final Set<String>? uuids;
  final String? error;
  final bool outdated;
}

const String _outdated = 'runs an older version and has to be updated';

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
        if (answer.outdated)
          LanTillGap(
            deviceId: answer.peer.deviceId,
            name: answer.peer.name,
            reason: _outdated,
            lastSeenAt: answer.peer.lastSeenAt,
          )
        else if (answer.error case final error?)
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
                ? '1 sale held there is not on this till yet'
                : '$short sales held there are not on this till yet',
            lastSeenAt: answer.peer.lastSeenAt,
          ),
    ];

/// A status the close reports while it collects the other tills, run through
/// [tr] the way [gapReasonIn] runs a reason. Till names stay as they came.
String closeProgressIn(String status, String Function(String en) tr) {
  if (RegExp(r'^Looking for (\d+) till\(s\)\.\.\.$').firstMatch(status)
      case final m?) {
    return tr('Looking for {n} till(s)...').replaceAll('{n}', m.group(1)!);
  }
  if (RegExp(r'^Pulling from (.+) \((\d+)/(\d+)\)\.\.\.$').firstMatch(status)
      case final m?) {
    return tr('Pulling from {who} ({i}/{n})...')
        .replaceAll('{i}', m.group(2)!)
        .replaceAll('{n}', m.group(3)!)
        .replaceAll('{who}', m.group(1)!);
  }
  if (RegExp(r'^Asking (.+) to collect every till\.\.\.$').firstMatch(status)
      case final m?) {
    return tr('Asking {who} to collect every till...')
        .replaceAll('{who}', m.group(1)!);
  }
  return tr(status);
}

/// A [LanTillGap.reason], which is English on the wire, run through [tr] for
/// the cashier's language. Reasons it does not know are returned as they came.
String gapReasonIn(String reason, String Function(String en) tr) {
  if (reason == 'the primary is not on the network' || reason == _outdated) {
    return tr(reason);
  }
  if (RegExp(r'^(\d+) sales? held there (?:is|are) not on this till yet$')
          .firstMatch(reason)
      case final m?) {
    final n = m.group(1)!;
    return n == '1'
        ? tr('1 sale held there is not on this till yet')
        : tr('{n} sales held there are not on this till yet')
            .replaceAll('{n}', n);
  }
  const unlisted = 'could not list its sales: ';
  if (reason.startsWith(unlisted)) {
    return '${tr('could not list its sales')}: '
        '${reason.substring(unlisted.length)}';
  }
  return reason;
}
