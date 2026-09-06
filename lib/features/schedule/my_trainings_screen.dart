import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/upcoming.dart';
import '../profile/profile_screen.dart';
import 'cancel_own_reservation.dart';

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final today = Day.fromDateTime(now);
    // Primary data: the timeline is meaningless without it, so a slow or
    // failed stream must never fall through to the empty state's "Zatím
    // nic." — that would be a false claim right after sign-in, a tenant
    // switch, or on a slow network. myProfileProvider stays a silent
    // fallback (as WeekScreen treats its own secondary providers): missing
    // followed teams just means the hint line shows instead of matches.
    final reservationsAsync = ref.watch(myActiveReservationsProvider);
    final blocksAsync = ref.watch(timeBlocksProvider);
    final profile = ref.watch(myProfileProvider).value;
    final teams = profile?.followedTeams ?? const <String>[];
    final theme = Theme.of(context);

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text('Moje tréninky', style: theme.textTheme.titleLarge),
          ),
          ...trailing,
        ],
      ),
    );

    final stillLoading =
        (reservationsAsync.isLoading && !reservationsAsync.hasValue) ||
            (blocksAsync.isLoading && !blocksAsync.hasValue);
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
            (blocksAsync.hasError && !blocksAsync.hasValue);
    if (failedToLoad) {
      return Column(
        children: [
          header,
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Tréninky se nepodařilo načíst.'),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () {
                      ref.invalidate(myActiveReservationsProvider);
                      ref.invalidate(timeBlocksProvider);
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
      slots: ref.watch(prioritySlotsProvider),
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
                    UpcomingTraining() => ListTile(
                        leading: const Icon(Icons.sports_outlined),
                        title: Text(
                          '${item.block.label} · Dráha ${item.reservation.lane}',
                        ),
                        trailing: const Icon(Icons.close),
                        onTap: () => _confirmCancel(context, item),
                      ),
                    UpcomingMatch() => ListTile(
                        leading: const Icon(Icons.emoji_events_outlined),
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
              if (teams.isEmpty)
                ListTile(
                  leading: Icon(Icons.info_outline,
                      color: theme.colorScheme.outline),
                  title: Text(
                    'Zápasy svých týmů tu uvidíš, když si je vybereš v '
                    'Můj profil → Moje týmy.',
                    style: theme.textTheme.bodySmall,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ProfileScreen()),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
