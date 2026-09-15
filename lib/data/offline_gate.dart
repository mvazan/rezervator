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
///
/// [everConnected] is the launch rule: a socket that has never been up is
/// being DIALLED, not down. Supabase opens it only once the first stream
/// subscribes, and a slow first connection — a cold start, a token being
/// refreshed, a phone still finding the network — looked exactly like an
/// outage to a poll that sees nothing but a boolean. So the app accused
/// itself of being offline a few seconds after every launch, while it was
/// busy connecting. Nothing is lost by staying quiet: the screens show
/// cached data either way, and anything the player actually tries says
/// "Jsi offline" from friendlyDbError the moment it fails.
({bool offline, DateTime? disconnectedSince}) offlineDecision({
  required bool connected,
  required bool everConnected,
  required DateTime now,
  required DateTime wokeAt,
  required DateTime? disconnectedSince,
}) {
  if (connected) return (offline: false, disconnectedSince: null);
  if (!everConnected) return (offline: false, disconnectedSince: null);
  final since = disconnectedSince ?? now;
  final downFor = now.difference(since);
  final awakeFor = now.difference(wokeAt);
  final offline = downFor >= offlineGrace && awakeFor >= offlineGrace;
  return (offline: offline, disconnectedSince: since);
}
