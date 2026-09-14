/// Výjimky: the one-match answers, where the team's answer is the wrong
/// size.
///
/// Teams decide wholesale — follow the A team and its whole season is
/// yours. But sometimes it is about ONE match: you are turning out for the
/// A team, or the match is simply worth watching; and the other way round,
/// next weekend you are away and would rather not see it at all. The screen
/// records the decision and never asks why.
///
/// It lists the WHOLE upcoming schedule, ticked where the match is already
/// yours. A filtered list would shift under the player every time they
/// picked a team on another screen — and hiding a match needs the match to
/// be there in the first place. What it does instead is show, up top, the
/// handful of matches where the player has overruled their teams, each with
/// an ✕ that hands it back.
///
/// Nothing is stored when the tick agrees with the teams: taking an
/// exception back is deleting a row, not ticking a third state, so the list
/// up top cannot fill with decisions the teams already make.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config.dart';
import '../../core/ui.dart';
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/upcoming.dart';

class MatchExceptionsScreen extends ConsumerStatefulWidget {
  const MatchExceptionsScreen({super.key, this.setMatchException});

  /// Injectable for widget tests (the Api one needs a live Supabase client).
  final Future<void> Function(String matchId, bool? shown)? setMatchException;

  @override
  ConsumerState<MatchExceptionsScreen> createState() =>
      _MatchExceptionsScreenState();
}

class _MatchExceptionsScreenState extends ConsumerState<MatchExceptionsScreen> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// Dnes / Zítra / "čtvrtek 17. 9." — the same heading Můj přehled uses, so
  /// the two lists read as the same kind of list.
  static String _dayLabel(Day date, Day today) {
    if (date == today) return 'Dnes';
    if (date == today.addDays(1)) return 'Zítra';
    return dayFull(date);
  }

  static String _when(PrioritySlot slot) => [
        '${slot.startsAt.display()}–${slot.endsAt.display()}',
        slot.isAway ? 'venku' : 'doma',
        if (slot.description.isNotEmpty) slot.description,
      ].join(' · ');

  Future<void> _set(String matchId, bool? shown) => tryAction(
        context,
        () => (widget.setMatchException ?? Api.setMatchException)(
            matchId, shown),
        errorText: friendlyDbError,
      );

  @override
  Widget build(BuildContext context) {
    final today =
        Day.fromDateTime(ref.watch(nowProvider).value ?? DateTime.now());
    final slots = ref.watch(prioritySlotsProvider);
    final slotsLoading = ref.watch(prioritySlotsLoadingProvider);
    final slotsFailed = ref.watch(prioritySlotsFailedProvider);
    final profile = ref.watch(myProfileProvider).value;
    final teams = profile?.followedTeams ?? const <String>[];
    final exceptions =
        ref.watch(myMatchExceptionsProvider).value ?? const <String, bool>{};
    final link = ref.watch(myCalendarLinkProvider).value ?? CalendarLink.none;
    final hasCalendar = ref.watch(calendarAvailableProvider) &&
        !AppConfig.isDemoAccount(profile?.email ?? '') &&
        link.isLinked;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Výjimky')),
      body: switch ((slotsLoading, slotsFailed)) {
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
        _ => _body(
            today: today,
            slots: slots,
            teams: teams,
            exceptions: exceptions,
            hasCalendar: hasCalendar,
            secondary: hasCalendar && link.secondaryEnabled,
            theme: theme,
          ),
      },
    );
  }

  Widget _body({
    required Day today,
    required List<PrioritySlot> slots,
    required List<String> teams,
    required Map<String, bool> exceptions,
    required bool hasCalendar,
    required bool secondary,
    required ThemeData theme,
  }) {
    // The overruled matches, oldest first — the same order as the schedule
    // below, so the two lists never disagree about which match comes first.
    final byId = {for (final s in slots) s.id: s};
    final overruled = [
      for (final entry in exceptions.entries)
        if (byId[entry.key] case final slot?) (slot, entry.value),
    ]..sort((a, b) =>
        compareDayTime(a.$1.date, a.$1.startsAt, b.$1.date, b.$1.startsAt));

    final matches = upcomingMatches(
      slots: slots,
      today: today,
      query: _query.text,
    );
    final days = <Day, List<PrioritySlot>>{};
    for (final slot in matches) {
      (days[slot.date] ??= []).add(slot);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'Zápasy, které chceš v přehledu navíc — nebo naopak nevidět.',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            // "Hlavní" means nothing to someone who has one calendar.
            !hasCalendar
                ? 'Přidaný zápas uvidíš v Můj přehled.'
                : secondary
                    ? 'Přidaný zápas uvidíš v Můj přehled a přijde ti do '
                        'hlavního Google kalendáře.'
                    : 'Přidaný zápas uvidíš v Můj přehled a přijde ti do '
                        'Google kalendáře.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        if (overruled.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Tvoje výjimky', style: theme.textTheme.titleSmall),
          ),
          for (final (slot, shown) in overruled)
            ListTile(
              key: ValueKey('exception:${slot.id}'),
              dense: true,
              leading: Icon(
                shown ? Icons.add_circle_outline : Icons.visibility_off_outlined,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              title: Text(slot.title),
              subtitle: Text(
                '${dayLabel(slot.date)} · ${shown ? 'přidáno' : 'skryto'}',
              ),
              trailing: IconButton(
                tooltip: 'Zrušit výjimku',
                icon: const Icon(Icons.close),
                // Back to whatever the teams say — which is deleting the
                // row, not ticking the opposite.
                onPressed: () => _set(slot.id, null),
              ),
            ),
          const Divider(height: 24),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: TextField(
            controller: _query,
            decoration: const InputDecoration(
              labelText: 'Hledat tým',
              prefixIcon: Icon(Icons.search),
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        if (matches.isEmpty)
          ListTile(
            leading: Icon(Icons.emoji_events_outlined,
                color: theme.colorScheme.outline),
            title: Text(_query.text.trim().isEmpty
                ? 'V rozpisu nejsou žádné další zápasy'
                : 'Nikdo neodpovídá hledání'),
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
            _matchRow(slot, teams: teams, exceptions: exceptions),
        ],
      ],
    );
  }

  Widget _matchRow(
    PrioritySlot slot, {
    required List<String> teams,
    required Map<String, bool> exceptions,
  }) {
    final mine = matchIsMine(slot, teams, exceptions);
    final fromTeam =
        teams.contains(slot.homeTeam) || teams.contains(slot.awayTeam);
    return CheckboxListTile(
      key: ValueKey(slot.id),
      value: mine,
      title: Text(slot.title),
      subtitle: Text(_when(slot)),
      // Ticking back to what the teams say stores nothing: the exception is
      // dropped instead, so an untouched decision never becomes a row.
      onChanged: (on) => _set(slot.id, (on == true) == fromTeam ? null : on),
    );
  }
}
