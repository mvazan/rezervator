import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/collation.dart';
import '../../../domain/models.dart';
import 'event_color_picker.dart';

/// Zápasy v kalendáři: the richer sibling of `showTeamPickerSheet` — one row
/// per team with not just a tick but a colour, and, once the second
/// calendar is on, which of the two it goes to. Every change saves the
/// WHOLE list of ticked teams at once via [onChanged] (the shape
/// `Api.setCalendarTeams` takes), queued the same way `showTeamPickerSheet`
/// queues its own saves: two quick taps must not become two whole-list
/// PATCHes racing over separate connections, where the older one can land
/// last and silently drop the newer change. Unlike that sheet, a save here
/// must also never lose an untouched row's OWN calendar/colour just because
/// some other row changed — that is the whole point of this richer sheet
/// over Task 4's transitional "every ticked team to primary, no colour"
/// shim.
///
/// Reads [myCalendarTeamsProvider] (which teams are chosen, and each one's
/// calendar/colour), [ourTeamsProvider] (the alley's own teams, from the
/// schedule) and [myCalendarLinkProvider] (whether the second calendar is
/// on — the Hlavní/Druhý picker only shows once it is) directly, so the one
/// call site (the calendar card's "Zápasy v kalendáři…" row) has nothing
/// left to inject beyond the save itself.
Future<void> showCalendarTeamsSheet(
  BuildContext context, {
  required Future<void> Function(List<CalendarTeam> teams) onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => Consumer(
      builder: (context, ref, _) {
        final chosen = ref.watch(myCalendarTeamsProvider).value ?? const [];
        final secondaryEnabled =
            ref.watch(myCalendarLinkProvider).value?.secondaryEnabled ?? false;
        final names = {
          ...ref.watch(ourTeamsProvider),
          for (final t in chosen) t.team,
        }.toList()..sort(compareCzech);
        return _CalendarTeamsList(
          teams: names,
          chosen: chosen,
          secondaryEnabled: secondaryEnabled,
          onChanged: onChanged,
        );
      },
    ),
  );
}

/// The list itself, with a local ticked-map overlay on top of [chosen] —
/// same reasoning as `showTeamPickerSheet`'s `_TeamPickerList`, except each
/// entry carries a whole [CalendarTeam] (calendar + colour), not just a
/// name, so a tap must show its result right away without losing what the
/// OTHER rows already hold.
class _CalendarTeamsList extends StatefulWidget {
  const _CalendarTeamsList({
    required this.teams,
    required this.chosen,
    required this.secondaryEnabled,
    required this.onChanged,
  });

  final List<String> teams;
  final List<CalendarTeam> chosen;
  final bool secondaryEnabled;
  final Future<void> Function(List<CalendarTeam> teams) onChanged;

  @override
  State<_CalendarTeamsList> createState() => _CalendarTeamsListState();
}

class _CalendarTeamsListState extends State<_CalendarTeamsList> {
  late Map<String, CalendarTeam> _ticked = {
    for (final t in widget.chosen) t.team: t,
  };

  /// Saves go out one after the other: two quick taps must not become two
  /// whole-list PATCHes racing over separate connections, where the older
  /// one can land last and silently drop the newer change.
  Future<void> _queue = Future.value();
  int _pending = 0;

  @override
  void didUpdateWidget(_CalendarTeamsList old) {
    super.didUpdateWidget(old);
    // Only a genuine change from upstream resyncs the overlay, and only
    // while no save is in flight — a rebuild triggered by something else
    // (e.g. the schedule changing) or an older save's row arriving mid-queue
    // must not clobber a tap that is still on its way. Same guard as
    // showTeamPickerSheet.
    if (_pending == 0 && !_sameChosen(old.chosen, widget.chosen)) {
      _ticked = {for (final t in widget.chosen) t.team: t};
    }
  }

  static bool _sameChosen(List<CalendarTeam> a, List<CalendarTeam> b) {
    if (a.length != b.length) return false;
    final byName = {for (final t in a) t.team: t};
    for (final t in b) {
      final other = byName[t.team];
      if (other == null ||
          other.calendar != t.calendar ||
          other.colorId != t.colorId) {
        return false;
      }
    }
    return true;
  }

  List<CalendarTeam> _sortedTicked() =>
      _ticked.values.toList()..sort((a, b) => compareCzech(a.team, b.team));

  /// Replaces [team]'s row with [next] (drops it when null), saves the
  /// whole list, and — only if the save fails — restores exactly the row
  /// that was there before, not a fresh default. That is what keeps a
  /// failed colour or calendar change from silently resetting the team to
  /// "no colour, hlavní" on retry.
  void _replace(String team, CalendarTeam? next) {
    final previous = _ticked[team];
    setState(() {
      if (next == null) {
        _ticked.remove(team);
      } else {
        _ticked[team] = next;
      }
    });
    final snapshot = _sortedTicked();
    _pending++;
    _queue = _queue.then((_) => _save(snapshot, team, previous));
  }

  Future<void> _save(
    List<CalendarTeam> snapshot,
    String team,
    CalendarTeam? previous,
  ) async {
    if (!mounted) {
      _pending--;
      return;
    }
    final saved = await tryAction(
      context,
      () => widget.onChanged(snapshot),
      errorText: friendlyDbError,
    );
    _pending--;
    if (!saved && mounted) {
      setState(() {
        if (previous == null) {
          _ticked.remove(team);
        } else {
          _ticked[team] = previous;
        }
      });
    }
  }

  void _toggle(String team, bool on) =>
      _replace(team, on ? CalendarTeam(team: team) : null);

  void _setColor(String team, int? colorId) {
    final current = _ticked[team];
    if (current == null) return;
    _replace(
      team,
      CalendarTeam(team: team, calendar: current.calendar, colorId: colorId),
    );
  }

  void _setCalendar(String team, CalendarSlot slot) {
    final current = _ticked[team];
    if (current == null) return;
    _replace(
      team,
      CalendarTeam(team: team, calendar: slot, colorId: current.colorId),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'Zápasy v kalendáři',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Vyber svůj tým — jeho domácí i venkovní zápasy se '
              'přidají do kalendáře.',
            ),
          ),
          if (widget.teams.isEmpty)
            const ListTile(
              leading: Icon(Icons.emoji_events_outlined),
              title: Text('Zatím žádné zápasy v rozvrhu'),
            ),
          for (final team in widget.teams) _teamRow(team),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _teamRow(String team) {
    final entry = _ticked[team];
    return Column(
      key: ValueKey(team),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: Checkbox(
            value: entry != null,
            onChanged: (on) => _toggle(team, on == true),
          ),
          title: Text(team),
          // Unticked, the row itself is a bigger target for turning it on;
          // ticked, the row also hosts the colour dot (and, below, the
          // calendar picker) so only the checkbox turns it back off — same
          // reasoning `CalendarLinkCard` follows for its own trailing
          // controls (no ListTile.onTap once a trailing button is live).
          onTap: entry == null ? () => _toggle(team, true) : null,
          trailing: entry == null
              ? null
              : EventColorDot(
                  colorId: entry.colorId,
                  onTap: () async {
                    final picked = await pickEventColor(
                      context,
                      current: entry.colorId,
                      title: 'Barva – $team',
                    );
                    if (picked != entry.colorId) _setColor(team, picked);
                  },
                ),
        ),
        if (entry != null && widget.secondaryEnabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
            child: SegmentedButton<CalendarSlot>(
              segments: const [
                ButtonSegment(
                  value: CalendarSlot.primary,
                  label: Text('Hlavní'),
                ),
                ButtonSegment(
                  value: CalendarSlot.secondary,
                  label: Text('Druhý'),
                ),
              ],
              selected: {entry.calendar},
              onSelectionChanged: (s) => _setCalendar(team, s.first),
            ),
          ),
      ],
    );
  }
}
