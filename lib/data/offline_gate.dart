/// Deciding when the app is really offline, rather than merely between
/// sockets.
///
/// Pure so it can be tested without waiting on real clocks; the provider in
/// providers.dart is a thin poll around it.
library;

/// How long the backend has to STAY unreachable before the banner is fair.
///
/// The socket is legitimately down for a moment on every resume: Supabase
/// closes it while the app is in the background and dials again on the way
/// back. Reporting that as "Offline" made the banner flash on every return
/// from a minimised app.
const offlineGrace = Duration(seconds: 6);

/// Whether to say "Offline", and the time the socket went down.
///
/// [disconnectedSince] is this function's own memory — pass back what it
/// returned last time, `null` on the first call.
///
/// The rule is deliberately about PERSISTENCE, not about catching the wake:
/// an earlier attempt suppressed the banner for [offlineGrace] after a wake
/// event, which failed two ways. The poll and the wake event race, so a tick
/// could land first and flash the banner before the wake was recorded; and
/// LiveRefresh throttles its own signal to one per two seconds, so a quick
/// app switch produced no wake event at all. Asking "has it been down all
/// this time?" needs neither signal to arrive on time.
///
/// [wokeAt] still counts: a resume also restarts the grace, so a socket that
/// went down BEFORE the app was minimised does not report offline the
/// instant it comes back — it gets the same fair chance to reconnect.
///
/// [reachable] is the answer to the question the banner actually asks, and
/// it is NOT the socket's state. A socket that is not up is being DIALLED as
/// often as it is down — supabase opens it only once the first stream
/// subscribes, so right after launch "not connected" is the normal state,
/// not an outage. The poll used to see nothing but that boolean and accused
/// the app of being offline a few seconds after every start.
///
/// So when the socket is not up, someone has to ASK: one HTTP request to the
/// backend (backend_reachable.dart). An answer means the network path works
/// and the app is merely connecting — quiet. A refused connection or a
/// timeout means offline, and then the banner is the truth, including on a
/// launch with no network at all.
({bool offline, DateTime? disconnectedSince}) offlineDecision({
  required bool reachable,
  required DateTime now,
  required DateTime wokeAt,
  required DateTime? disconnectedSince,
}) {
  if (reachable) return (offline: false, disconnectedSince: null);
  final since = disconnectedSince ?? now;
  final downFor = now.difference(since);
  final awakeFor = now.difference(wokeAt);
  final offline = downFor >= offlineGrace && awakeFor >= offlineGrace;
  return (offline: offline, disconnectedSince: since);
}
