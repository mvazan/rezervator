import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/palette.dart';
import '../../domain/results.dart'
    show displayWinner, hasScoreData, pointsLabel;
import '../../domain/upcoming.dart';
import '../clubhouse/match_detail_screen.dart';
import '../clubhouse/widgets/match_title.dart';
import '../profile/profile_screen.dart';
import 'cancel_own_reservation.dart';
import 'widgets/home_header.dart';

/// Fixed-width, centred slot every list row's leading sits in, so the match
/// trophy dots and the training T line up down one straight column however
/// wide each glyph is (a 36 dp dot beside a 24 dp letter would otherwise
/// read ragged).
class _LeadingSlot extends StatelessWidget {
  const _LeadingSlot({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      SizedBox(width: 40, height: 40, child: Center(child: child));
}

/// A match's trophy in the overview: a filled dot in the followed team's own
/// Google colour (like `EventColorDot`, the app's established colour token)
/// so a change of colour is unmissable — an outlined glyph tinted a legible
/// shade, which is what this used to be, put too little ink on screen to
/// notice. [colorId] is [matchColorOf]'s pick (home wins a derby, no
/// fall-through to a coloured team the player does not follow). Null — no
/// followed team is coloured — keeps today's plain outlined trophy, so an
/// uncoloured match is not dressed up as a coloured one.
class MatchTrophy extends StatelessWidget {
  const MatchTrophy({super.key, required this.colorId});

  final int? colorId;

  @override
  Widget build(BuildContext context) {
    final raw = _rawEventColor(colorId);
    if (raw == null) {
      return const _LeadingSlot(child: Icon(Icons.emoji_events_outlined));
    }
    return _LeadingSlot(
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: raw,
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Icon(Icons.emoji_events, size: 20, color: _legibleOn(raw)),
      ),
    );
  }
}

/// The raw Google RGB for [colorId] (the dot fill), or null for "no colour"
/// and any id that is none of the eleven.
Color? _rawEventColor(int? colorId) {
  if (colorId == null) return null;
  for (final (id, _, color) in googleEventColors) {
    if (id == colorId) return color;
  }
  return null;
}

/// Black or white glyph, whichever reads on [color] — the eleven are fixed
/// RGBs, so contrast goes by luminance (as `EventColorPicker` does).
Color _legibleOn(Color color) =>
    color.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;

/// One Google event colour id as a shade legible on [brightness]'s surface,
/// or null for "no colour" — the plain icon. Shared by the match trophy and
/// the training T so the two can never drift into different shades of the
/// same picked colour.
Color? eventShadeOf(int? colorId, Brightness brightness) {
  if (colorId == null) return null;
  for (final (id, _, color) in googleEventColors) {
    if (id == colorId) return legibleShadeOf(color, brightness);
  }
  return null;
}

/// The second view beside the calendar: what is coming for the player — the
/// trainings they booked and the matches of the teams they follow, by day.
/// A training can be cancelled here (own future reservation, the same
/// confirm as the calendar); a match opens its detail once it has actually
/// started — an upcoming one has nothing to show there yet, so it stays
/// unclickable.
class MyTrainingsScreen extends ConsumerStatefulWidget {
  const MyTrainingsScreen({
    super.key,
    this.trailing = const [],
    required this.onOpenCalendar,
    this.cancelReservation = _cancel,
  });

  /// The shell's icons, on the same top line as the title — like the week
  /// header of the calendar.
  final List<Widget> trailing;

  /// „Do kalendáře" in the empty state: the shell switches the view.
  final VoidCallback onOpenCalendar;

  /// Injectable for widget tests (the Api one needs a live client).
  final Future<void> Function(String id) cancelReservation;

  static Future<void> _cancel(String id) => Api.cancelReservation(id);

  @override
  ConsumerState<MyTrainingsScreen> createState() => _MyTrainingsScreenState();
}

class _MyTrainingsScreenState extends ConsumerState<MyTrainingsScreen> {
  bool _scrolledToUpcoming = false;
  final Map<Day, GlobalKey> _dayKeys = {};

  GlobalKey _keyFor(Day day) => _dayKeys.putIfAbsent(day, GlobalKey.new);

  Future<void> _confirmCancel(BuildContext context, UpcomingTraining t) =>
      confirmCancelOwnReservation(
        context,
        reservation: t.reservation,
        block: t.block,
        cancel: widget.cancelReservation,
      );

  static String _dayLabel(Day date, Day today) {
    if (date == today) return 'Dnes';
    if (date == today.addDays(1)) return 'Zítra';
    return dayFull(date);
  }

  /// [started]: today's block has already begun (mirrors the calendar's own
  /// `canCancel`/`inPast` check — see `domain/schedule.dart`) — no tap, no
  /// close icon, but still listed: the player did train, after all.
  Widget _trainingTile(
    BuildContext context,
    UpcomingTraining item,
    bool started,
    Color? color,
  ) => ListTile(
    leading: _LeadingSlot(child: Icon(Icons.title, color: color)),
    title: Text('${item.block.label} · Dráha ${item.reservation.lane}'),
    trailing: started ? null : const Icon(Icons.close),
    onTap: started ? null : () => _confirmCancel(context, item),
  );

  /// „Zápasy svých týmů…" hint — shown wherever the player follows no teams:
  /// the list's footer, and the empty state below „Do kalendáře". One widget
  /// for both spots so the copy and the tap target can't drift apart.
  static Widget _followTeamsHint(BuildContext context, ThemeData theme) =>
      ListTile(
        leading: Icon(Icons.info_outline, color: theme.colorScheme.outline),
        title: Text(
          'Zápasy svých týmů tu uvidíš, když si je vybereš v '
          'Můj profil → Moje týmy.',
          style: theme.textTheme.bodySmall,
        ),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const ProfileScreen())),
      );

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final today = Day.fromDateTime(now);
    final nowTime = HourMinute(now.hour, now.minute);
    // Primary data: the timeline is meaningless without it, so a slow or
    // failed stream must never fall through to the empty state's "Zatím
    // nic." — that would be a false claim right after sign-in, a tenant
    // switch, or on a slow network. myProfileProvider stays a silent
    // fallback (as WeekScreen treats its own secondary providers): missing
    // followed teams just means the hint line shows instead of matches.
    final reservationsAsync = ref.watch(myActiveReservationsProvider);
    final blocksAsync = ref.watch(timeBlocksProvider);
    // Hoisted up here (not down by the empty-state check) so this stream —
    // and prioritySlotsLoadingProvider below — starts on the SAME frame as
    // reservations/blocks; created only after the loading gate, it would
    // still be pending on the first build past that gate and a player who
    // follows teams but has no reservation would see "Zatím nic." for one
    // round trip.
    final slots = ref.watch(prioritySlotsProvider);
    final slotsLoading = ref.watch(prioritySlotsLoadingProvider);
    final slotsFailed = ref.watch(prioritySlotsFailedProvider);
    final profileAsync = ref.watch(myProfileProvider);
    final profile = profileAsync.value;
    final teams = profile?.followedTeams ?? const <String>[];
    final teamColors = ref.watch(myTeamColorsProvider).value ?? const {};
    // Matches played for somebody else's team (0039) belong on this list
    // like any other — nothing marks them out, they simply are the
    // player's.
    final exceptionsAsync = ref.watch(myMatchExceptionsProvider);
    final exceptions = exceptionsAsync.value ?? const <String, bool>{};
    // Score trailing on a federation match's row (Task 3) — read here since
    // Můj přehled did not watch it before.
    final results =
        ref.watch(matchResultsProvider).value ?? const <String, MatchResult>{};
    // A training's own colour, the one set under Barva tréninků — the same
    // value that colours it in Google Calendar, so the T here and the event
    // there read as the same thing.
    final trainingColorId = ref
        .watch(myCalendarLinkProvider)
        .value
        ?.trainingColorId;
    final theme = Theme.of(context);
    final trainingColor = eventShadeOf(trainingColorId, theme.brightness);

    // The calendar's strip, minus the week navigation: the same title in
    // the same place and the same icons at the same right edge, so nothing
    // moves when the tabs switch. Which view this is, the tabs say.
    final header = HomeHeader(trailing: widget.trailing);

    final stillLoading =
        (reservationsAsync.isLoading && !reservationsAsync.hasValue) ||
        (blocksAsync.isLoading && !blocksAsync.hasValue) ||
        slotsLoading;
    if (stillLoading) {
      return Column(
        children: [
          header,
          const Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      );
    }

    final failedToLoad =
        (reservationsAsync.hasError && !reservationsAsync.hasValue) ||
        (blocksAsync.hasError && !blocksAsync.hasValue) ||
        slotsFailed;
    if (failedToLoad) {
      return Column(
        children: [
          header,
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Přehled se nepodařilo načíst.'),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () {
                      ref.invalidate(myActiveReservationsProvider);
                      ref.invalidate(timeBlocksProvider);
                      retryPrioritySlots(ref);
                    },
                    child: const Text('Zkusit znovu'),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final days = upcomingTimeline(
      reservations: reservationsAsync.value ?? const [],
      blocks: blocksAsync.value ?? const [],
      slots: slots,
      teams: teams,
      today: today,
      exceptions: exceptions,
    );

    if (days.isEmpty) {
      return Column(
        children: [
          header,
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Zatím nic.', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  const Text('Trénink si rezervuješ v kalendáři.'),
                  const SizedBox(height: 16),
                  FilledButton.tonal(
                    onPressed: widget.onOpenCalendar,
                    child: const Text('Do kalendáře'),
                  ),
                  if (teams.isEmpty) ...[
                    const SizedBox(height: 16),
                    _followTeamsHint(context, theme),
                  ],
                ],
              ),
            ),
          ),
        ],
      );
    }

    // Waits for the profile and exceptions streams too (not just slots):
    // upcomingTimeline's `days` also depends on `teams`/`exceptions`, so
    // latching this on their pre-stream fallback values (`[]`/`{}`) would
    // scroll to a partial list's index and never revisit once the real
    // teams/exceptions arrive — same race class results_screen.dart's own
    // recentResultsIndex gate was fixed for. A failed stream unblocks the
    // scroll too (like it does everywhere else on this screen, see
    // `stillLoading` above): either stream's own fallback (`[]`/`{}`) is
    // then already final, and waiting forever for a value that will never
    // come would leave the screen stuck unscrolled.
    final upcomingIdx = upcomingScrollIndex(days, today);
    if (!slotsLoading &&
        (profileAsync.hasValue || profileAsync.hasError) &&
        (exceptionsAsync.hasValue || exceptionsAsync.hasError) &&
        !_scrolledToUpcoming &&
        upcomingIdx >= 0) {
      _scrolledToUpcoming = true;
      final key = _keyFor(days[upcomingIdx].date);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = key.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(ctx, alignment: 0, duration: Duration.zero);
        }
      });
    }

    return Column(
      children: [
        header,
        Expanded(
          // A plain, eagerly built scroll view (not a lazy ListView) — same
          // reason as results_screen.dart's own list: Scrollable.ensureVisible
          // above needs the target day header's element to already exist,
          // which a lazily built Sliver would not guarantee on the first
          // frame.
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final day in days) ...[
                  Padding(
                    key: _keyFor(day.date),
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      _dayLabel(day.date, today),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  for (final item in day.items)
                    switch (item) {
                      UpcomingTraining() => _trainingTile(
                        context,
                        item,
                        day.date == today &&
                            item.block.startsAt.minutesFromMidnight <=
                                nowTime.minutesFromMidnight,
                        trainingColor,
                      ),
                      UpcomingMatch() => ListTile(
                        leading: MatchTrophy(
                          colorId: matchColorOf(
                            item.slot,
                            teams,
                            teamColors,
                            exceptions: exceptions,
                          ),
                        ),
                        title: MatchTitle(
                          slot: item.slot,
                          winner: displayWinner(results[item.slot.id]),
                        ),
                        subtitle: Text(
                          [
                            '${item.slot.startsAt.display()}–'
                                '${item.slot.endsAt.display()}',
                            item.slot.isAway ? 'venku' : 'doma',
                            if (item.slot.description.isNotEmpty)
                              item.slot.description,
                          ].join(' · '),
                        ),
                        trailing:
                            item.slot.fromFederation &&
                                hasScoreData(results[item.slot.id])
                            ? Text(
                                pointsLabel(
                                  results[item.slot.id]?.homePoints,
                                  results[item.slot.id]?.awayPoints,
                                ),
                                style: theme.textTheme.bodyMedium,
                              )
                            : null,
                        // Only once the match has actually started (the
                        // same `hasScoreData` gate the trailing score
                        // above uses) — an upcoming match has nothing to
                        // show on the detail screen yet, so it stays
                        // read-only like the doc comment above says.
                        onTap:
                            item.slot.fromFederation &&
                                hasScoreData(results[item.slot.id])
                            ? () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => MatchDetailScreen(
                                    matchId: item.slot.id,
                                  ),
                                ),
                              )
                            : null,
                      ),
                    },
                ],
                if (teams.isEmpty) _followTeamsHint(context, theme),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
