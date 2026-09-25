/// Event wording shared by the in-grid tiles and the off-block bands.
/// Pure Dart — widgets only render these strings.
library;

import 'models.dart';
import 'schedule.dart';

/// '🏆 {title}' for matches, '⛔ {title}' for other blockages — the in-grid
/// and band wording (day headers keep headerEventLabel's 🏠/none/⛔).
String slotEventLabel(PrioritySlot m) =>
    '${m.type.isMatch ? '🏆' : '⛔'} ${m.title}';

/// '🔒 {renterName}', plus ' (výjimka)' for an occurrence an exception row
/// reshaped (fewer lanes / other times than the series).
String rentalLabel(Rental r) =>
    '🔒 ${r.renterName}${r.isOverridden ? ' (výjimka)' : ''}';

/// What an exception row changes against its series: 'vynecháno', else the
/// differing parts ('dráhy 1, 2', '17:00–18:00') joined by ' · ', or
/// 'beze změny' when nothing differs.
String rentalExceptionSummary(Rental parent, Rental child) {
  if (child.skipped) return 'vynecháno';
  final parts = [
    if (!_sameLanes(parent.lanes, child.lanes))
      'dráhy ${child.lanes.join(', ')}',
    if (child.startsAt != parent.startsAt || child.endsAt != parent.endsAt)
      '${child.startsAt.display()}–${child.endsAt.display()}',
  ];
  return parts.isEmpty ? 'beze změny' : parts.join(' · ');
}

bool _sameLanes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Czech plural: '1 výjimka' / '2–4 výjimky' / '5+ výjimek'.
String rentalExceptionCountLabel(int n) {
  if (n == 1) return '1 výjimka';
  if (n >= 2 && n <= 4) return '$n výjimky';
  return '$n výjimek';
}

/// After "včetně", which governs the genitive: 1 termínu, 2 termínů.
String rentalDateCountGenitive(int n) => n == 1 ? '1 termínu' : '$n termínů';

/// The tail of a group tile: how many dates its two shown lines leave out.
String rentalMoreDatesLabel(int n) {
  if (n == 1) return '…a ještě 1 termín';
  if (n >= 2 && n <= 4) return '…a další $n termíny';
  return '…a dalších $n termínů';
}

/// Band text: the label above + ' · od–do' using HourMinute.display().
String eventBandLabel(OffBlockEvent e) {
  final label = switch (e) {
    OffBlockPriority(:final slot) => slotEventLabel(slot),
    OffBlockRental(:final rental) => rentalLabel(rental),
  };
  return '$label · ${e.start.display()}–${e.end.display()}';
}

/// Why the ＋ is gone. The alley caps how many live future reservations one
/// player may hold (`max_active_reservations`); create_reservation refuses
/// anything past it with `limit_reached`, and the app simply stops offering
/// free slots — which, without a word, reads as a broken screen.
String reservationLimitNote(int max) =>
    'Máš maximální počet rezervací ($max). Další půjde, až jedna proběhne '
    'nebo ji zrušíš.';

/// The same fact in an ADMIN's booking dialog, where the cap is a warning
/// and not a wall: create_reservation lets an admin book past it. [player]
/// is null when the admin is booking for themself — "Admin Local už má…"
/// about oneself reads like a note about a stranger.
String reservationLimitAdminNote(String? player, int max) => player == null
    ? 'Máš už maximální počet rezervací ($max). Jako správce si ji můžeš '
        'vytvořit i tak.'
    : '$player už má maximální počet rezervací ($max). Jako správce ji můžeš '
        'vytvořit i tak.';

/// [n] with its noun in the right Czech form: [one] for 1, [few] for 2–4,
/// [many] for anything else (0, 5+, and 22 too — written in digits it takes
/// the genitive).
String czechCount(int n, String one, String few, String many) =>
    '$n ${n == 1 ? one : n >= 2 && n <= 4 ? few : many}';

/// The ČKA card's progress line while a discovery runs.
const teamsLoadingLabel = 'Načítají se týmy z webu…';

/// The ČKA card's progress line while federation jobs are still to run
/// (0046 `federation_sync_progress`): „Synchronizuje se… zbývá 12 zápasů,
/// 2 soutěže a 1 kuželna“ — only the non-zero counts, the verb agreeing
/// with the first of them. A discovery reads [teamsLoadingLabel].
String federationProgressLabel(FederationSyncProgress p) {
  if (p.discover > 0) return teamsLoadingLabel;
  final counts = [
    if (p.matches > 0)
      (p.matches, czechCount(p.matches, 'zápas', 'zápasy', 'zápasů')),
    if (p.competitions > 0)
      (
        p.competitions,
        czechCount(p.competitions, 'soutěž', 'soutěže', 'soutěží'),
      ),
    if (p.venues > 0)
      (p.venues, czechCount(p.venues, 'kuželna', 'kuželny', 'kuželen')),
  ];
  if (counts.isEmpty) return 'Synchronizuje se…';
  final first = counts.first.$1;
  final verb = first >= 2 && first <= 4 ? 'zbývají' : 'zbývá';
  final parts = [for (final (_, label) in counts) label];
  final list = parts.length == 1
      ? parts.single
      : '${parts.sublist(0, parts.length - 1).join(', ')} a ${parts.last}';
  return 'Synchronizuje se… $verb $list';
}
