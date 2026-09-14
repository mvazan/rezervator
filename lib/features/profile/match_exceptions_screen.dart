/// Výjimky: the matches a player is playing that their teams are not.
///
/// A B-team player turns out for the A team once. Following the A team for
/// it would drag in the rest of its season — every match in Můj přehled and
/// in Google — so this screen is per MATCH: tick the one you are playing.
/// It shows in the overview and goes to the main Google calendar (0039),
/// and the tick is the whole of the choice: someone who is playing wants it
/// where they live, not in the calendar they keep for watching.
///
/// A screen of its own rather than a control in Můj přehled, because it is
/// a rare thing to do and the overview is read every day. It offers only
/// what the player does not already have — see `exceptionCandidates`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config.dart';
import '../../core/ui.dart';
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/upcoming.dart';

class MatchExceptionsScreen extends ConsumerWidget {
  const MatchExceptionsScreen({super.key, this.setMatchException});

  /// Injectable for widget tests (the Api one needs a live Supabase client).
  final Future<void> Function(String matchId, bool on)? setMatchException;

  /// Dnes / Zítra / "čtvrtek 17. 9." — the same heading Můj přehled uses,
  /// so the two lists read as the same kind of list.
  static String _dayLabel(Day date, Day today) {
    if (date == today) return 'Dnes';
    if (date == today.addDays(1)) return 'Zítra';
    return dayFull(date);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final save = setMatchException ?? Api.setMatchException;
    final today = Day.fromDateTime(ref.watch(nowProvider).value ?? DateTime.now());
    final slots = ref.watch(prioritySlotsProvider);
    final slotsLoading = ref.watch(prioritySlotsLoadingProvider);
    final slotsFailed = ref.watch(prioritySlotsFailedProvider);
    final profile = ref.watch(myProfileProvider).value;
    final exceptions = ref.watch(myMatchExceptionsProvider).value ?? const <String>{};
    final link = ref.watch(myCalendarLinkProvider).value ?? CalendarLink.none;
    final hasCalendar = ref.watch(calendarAvailableProvider) &&
        !AppConfig.isDemoAccount(profile?.email ?? '') &&
        link.isLinked;
    final theme = Theme.of(context);

    final body = switch ((slotsLoading, slotsFailed)) {
      (true, _) => const Center(child: CircularProgressIndicator()),
      (_, true) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Zápasy se nepodařilo načíst.'),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => retryPrioritySlots(ref),
                child: const Text('Zkusit znovu'),
              ),
            ],
          ),
        ),
      _ => _list(
          context,
          ref,
          save: save,
          today: today,
          exceptions: exceptions,
          candidates: exceptionCandidates(
            slots: slots,
            followed: profile?.followedTeams ?? const [],
            routed: hasCalendar
                ? ref.watch(myCalendarTeamsProvider).value ?? const []
                : const [],
            hasCalendar: hasCalendar,
            exceptions: exceptions,
            today: today,
          ),
          hasCalendar: hasCalendar,
          theme: theme,
        ),
    };

    return Scaffold(
      appBar: AppBar(title: const Text('Výjimky')),
      body: body,
    );
  }

  Widget _list(
    BuildContext context,
    WidgetRef ref, {
    required Future<void> Function(String matchId, bool on) save,
    required Day today,
    required Set<String> exceptions,
    required List<PrioritySlot> candidates,
    required bool hasCalendar,
    required ThemeData theme,
  }) {
    // Grouped by day the way Můj přehled groups its timeline: one pass over
    // an already-sorted list.
    final days = <Day, List<PrioritySlot>>{};
    for (final slot in candidates) {
      (days[slot.date] ??= []).add(slot);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'Zápasy, které hraješ navíc — třeba když jdeš vypomoct áčku.',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            hasCalendar
                ? 'Zaškrtnutý zápas uvidíš v Můj přehled a přijde ti do '
                    'hlavního Google kalendáře.'
                : 'Zaškrtnutý zápas uvidíš v Můj přehled.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        if (candidates.isEmpty)
          ListTile(
            leading: Icon(Icons.emoji_events_outlined,
                color: theme.colorScheme.outline),
            title: const Text('Není co přidat'),
            subtitle: const Text(
              'Zápasy svých týmů už máš — tady jsou jen ty ostatní.',
            ),
          ),
        for (final entry in days.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              _dayLabel(entry.key, today),
              style: theme.textTheme.titleSmall,
            ),
          ),
          for (final slot in entry.value)
            CheckboxListTile(
              key: ValueKey(slot.id),
              value: exceptions.contains(slot.id),
              title: Text(slot.title),
              subtitle: Text([
                '${slot.startsAt.display()}–${slot.endsAt.display()}',
                slot.isAway ? 'venku' : 'doma',
                if (slot.description.isNotEmpty) slot.description,
              ].join(' · ')),
              // One tap, one answer — there is nothing here to batch, and
              // the Google side follows through the job queue anyway.
              onChanged: (on) => tryAction(
                context,
                () => save(slot.id, on == true),
                errorText: friendlyDbError,
              ),
            ),
        ],
      ],
    );
  }
}
