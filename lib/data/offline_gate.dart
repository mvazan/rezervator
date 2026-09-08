/// Deciding when the app is really offline, rather than merely between
/// sockets.
///
/// Pure so it can be tested without waiting on real clocks; the provider in
/// providers.dart is a thin poll around it.
library;

/// How long the socket has to STAY down before the banner is fair.
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
({bool offline, DateTime? disconnectedSince}) offlineDecision({
  required bool connected,
  required DateTime now,
  required DateTime wokeAt,
  required DateTime? disconnectedSince,
}) {
  if (connected) return (offline: false, disconnectedSince: null);
  final since = disconnectedSince ?? now;
  final downFor = now.difference(since);
  final awakeFor = now.difference(wokeAt);
  final offline = downFor >= offlineGrace && awakeFor >= offlineGrace;
  return (offline: offline, disconnectedSince: since);
}
