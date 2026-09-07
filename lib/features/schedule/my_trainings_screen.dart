import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/palette.dart';
import '../../domain/upcoming.dart';
import '../profile/profile_screen.dart';
import 'cancel_own_reservation.dart';

/// The trophy's colour for [slot]: [matchColorOf]'s pick among
/// [followedTeams] (home wins a derby, no fall-through to a coloured team
/// the player does not follow) from [teamColors], derived into a shade
/// legible for [brightness] (`legibleShadeOf`) rather than Google's raw
/// event RGB — a bare icon glyph needs more contrast than `EventColorDot`'s
/// filled, bordered circle. Null (today's plain icon) when neither team is
/// coloured, the picked team has no colour, or the id is somehow none of
/// the eleven.
Color? _trophyColorOf(
  PrioritySlot slot,
  List<String> followedTeams,
  Map<String, int> teamColors,
  Brightness brightness,
) =>
    eventShadeOf(matchColorOf(slot, followedTeams, teamColors), brightness);

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
/// confirm as the calendar); matches are read-only.
class MyTrainingsScreen extends ConsumerWidget {
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

  Future<void> _confirmCancel(BuildContext context, UpcomingTraining t) =>
      confirmCancelOwnReservation(
        context,
        reservation: t.reservation,
        block: t.block,
        cancel: cancelReservation,
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
  ) =>
      ListTile(
        leading: Icon(Icons.title, color: color),
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
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ProfileScreen()),
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
    final profile = ref.watch(myProfileProvider).value;
    final teams = profile?.followedTeams ?? const <String>[];
    final teamColors = ref.watch(myTeamColorsProvider).value ?? const {};
    // A training's own colour, the one set under Barva tréninků — the same
    // value that colours it in Google Calendar, so the T here and the event
    // there read as the same thing.
    final trainingColorId =
        ref.watch(myCalendarLinkProvider).value?.trainingColorId;
    final theme = Theme.of(context);
    final trainingColor =
        eventShadeOf(trainingColorId, theme.brightness);

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text('Můj přehled', style: theme.textTheme.titleLarge),
          ),
          ...trailing,
        ],
      ),
    );

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
                    onPressed: onOpenCalendar,
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

    return Column(
      children: [
        header,
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
            children: [
              for (final day in days) ...[
                Padding(
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
                        leading: Icon(
                          Icons.emoji_events_outlined,
                          color: _trophyColorOf(
                            item.slot,
                            teams,
                            teamColors,
                            theme.brightness,
                          ),
                        ),
                        title: Text(item.slot.title),
                        subtitle: Text([
                          '${item.slot.startsAt.display()}–'
                              '${item.slot.endsAt.display()}',
                          item.slot.isAway ? 'venku' : 'doma',
                          if (item.slot.description.isNotEmpty)
                            item.slot.description,
                        ].join(' · ')),
                      ),
                  },
              ],
              if (teams.isEmpty) _followTeamsHint(context, theme),
            ],
          ),
        ),
      ],
    );
  }
}
