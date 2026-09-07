import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/collation.dart';
import '../../../domain/models.dart';
import 'event_color_picker.dart';

/// Zápasy v kalendáři: the richer sibling of `showTeamPickerSheet` — one row
/// per team with not just a tick but a colour, and, once the second
/// calendar is on, which of the two it goes to.
///
/// Editing is local; the whole list goes out ONCE, when the sheet closes.
/// One save is an expensive round trip — the edge function refreshes the
/// Google token and rewrites every future match — so saving per tap meant
/// ticking three teams cost three of those, and the later ones could still
/// be waiting when the player closed the sheet. Nothing is lost by waiting:
/// the action takes the whole list anyway, so one call carries every change.
/// The snack belongs to the screen underneath, which is still there when
/// the answer comes back.
///
/// A save must never lose an untouched row's OWN calendar/colour just
/// because another row changed — that is the whole point of this richer
/// sheet over Task 4's transitional "every ticked team to primary, no
/// colour" shim.
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
}) async {
  List<CalendarTeam>? edited;
  List<CalendarTeam> opened = const [];
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => Consumer(
      builder: (context, ref, _) {
        final chosen = ref.watch(myCalendarTeamsProvider).value ?? const [];
        opened = chosen;
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
          onEdited: (teams) => edited = teams,
        );
      },
    ),
  );
  // Untouched, or fiddled back to where it started: nothing to send.
  if (edited == null || sameTeamChoices(opened, edited!)) return;
  if (!context.mounted) return;
  await tryAction(
    context,
    () => onChanged(edited!),
    errorText: friendlyDbError,
  );
}

/// Whether two team lists say the same thing — order included, since both
/// sides are kept Czech-sorted.
bool sameTeamChoices(List<CalendarTeam> a, List<CalendarTeam> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].team != b[i].team ||
        a[i].calendar != b[i].calendar ||
        a[i].colorId != b[i].colorId) {
      return false;
    }
  }
  return true;
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
    required this.onEdited,
  });

  final List<String> teams;
  final List<CalendarTeam> chosen;
  final bool secondaryEnabled;

  /// Reports the full list after every change; the caller sends the last one
  /// it heard once the sheet is closed.
  final void Function(List<CalendarTeam> teams) onEdited;

  @override
  State<_CalendarTeamsList> createState() => _CalendarTeamsListState();
}

class _CalendarTeamsListState extends State<_CalendarTeamsList> {
  late Map<String, CalendarTeam> _ticked = {
    for (final t in widget.chosen) t.team: t,
  };

  /// Set by the first change: from then on the player's edits own the list,
  /// not the stream underneath it.
  bool _edited = false;

  @override
  void didUpdateWidget(_CalendarTeamsList old) {
    super.didUpdateWidget(old);
    // Nothing has been saved yet, so an upstream change is simply newer
    // truth — until the player has touched something, in which case their
    // half-finished edit must not be clobbered by a rebuild.
    if (!_edited && !_sameChosen(old.chosen, widget.chosen)) {
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

  /// Replaces [team]'s row with [next] (drops it when null). Local only —
  /// the whole list goes out once, when the sheet closes.
  void _replace(String team, CalendarTeam? next) {
    setState(() {
      _edited = true;
      if (next == null) {
        _ticked.remove(team);
      } else {
        _ticked[team] = next;
      }
    });
    widget.onEdited(_sortedTicked());
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
