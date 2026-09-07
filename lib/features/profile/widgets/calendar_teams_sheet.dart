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

  /// The newest list waiting to go out, and whether one is already on its
  /// way. Every save carries the WHOLE list, so a change made while another
  /// save is in the air does not queue up behind it — it replaces what is
  /// waiting. One save is a slow round trip (the edge function refreshes the
  /// Google token and rewrites every future match), so ticking three teams
  /// in a row is one save with three ticks, not three saves.
  List<CalendarTeam>? _next;
  bool _sending = false;

  @override
  void didUpdateWidget(_CalendarTeamsList old) {
    super.didUpdateWidget(old);
    // Only a genuine change from upstream resyncs the overlay, and only
    // while no save is in flight — a rebuild triggered by something else
    // (e.g. the schedule changing) or an older save's row arriving mid-queue
    // must not clobber a tap that is still on its way. Same guard as
    // showTeamPickerSheet.
    if (!_sending && _next == null && !_sameChosen(old.chosen, widget.chosen)) {
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

  /// Replaces [team]'s row with [next] (drops it when null) and sends the
  /// whole list. The tick shows at once; the save follows.
  void _replace(String team, CalendarTeam? next) {
    setState(() {
      if (next == null) {
        _ticked.remove(team);
      } else {
        _ticked[team] = next;
      }
    });
    _next = _sortedTicked();
    _pump();
  }

  /// Sends the newest list, then whatever arrived while that was in the air.
  /// Deliberately outlives the sheet: closing it right after a tick used to
  /// throw away everything still waiting, so of three teams ticked in a row
  /// only the first ever reached Google.
  Future<void> _pump() async {
    if (_sending) return;
    _sending = true;
    final onChanged = widget.onChanged;
    while (_next != null) {
      final snapshot = _next!;
      _next = null;
      final saved = mounted
          ? await tryAction(
              context,
              () => onChanged(snapshot),
              errorText: friendlyDbError,
            )
          : await _sendDetached(onChanged, snapshot);
      // One save now covers several changes, so a failure rolls the whole
      // list back to what the server last confirmed — restoring just one
      // row would leave the others showing a state nobody saved.
      if (!saved && mounted && _next == null) {
        setState(() => _ticked = {for (final t in widget.chosen) t.team: t});
      }
    }
    _sending = false;
  }

  /// The sheet is gone, so there is nobody to show a snack to — but the
  /// change the player made before closing it still deserves to land.
  Future<bool> _sendDetached(
    Future<void> Function(List<CalendarTeam>) onChanged,
    List<CalendarTeam> snapshot,
  ) async {
    try {
      await onChanged(snapshot);
      return true;
    } catch (error) {
      debugPrint('calendar teams save after the sheet closed failed: $error');
      return false;
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
