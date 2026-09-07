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
/// A save must never lose an untouched row's OWN calendar just because
/// another row changed — that is the whole point of this richer sheet over
/// Task 4's transitional "every ticked team to primary, no colour" shim.
///
/// The colour dot edits a colour registry (`team_colors`, 0036,
/// [myTeamColorsProvider]/[Api.setTeamColors]) that is SHARED with
/// `showTeamPickerSheet`'s own sheet and with Můj přehled's trophy —
/// independent of [onChanged]/`calendar_teams` here, so picking a colour
/// never touches which calendar a team is routed to, and goes out through
/// its own call, [onColorsChanged] (the line under the heading says where
/// else it shows).
///
/// Reads [myCalendarTeamsProvider] (which teams are chosen, and each one's
/// calendar), [myTeamColorsProvider] (their shared colour), [ourTeamsProvider]
/// (the alley's own teams, from the schedule) and [myCalendarLinkProvider]
/// (whether the second calendar is on — the Hlavní/Druhý picker only shows
/// once it is) directly, so the one call site (the calendar card's "Zápasy
/// v kalendáři…" row) has nothing left to inject beyond the saves
/// themselves.
Future<void> showCalendarTeamsSheet(
  BuildContext context, {
  required Future<void> Function(List<CalendarTeam> teams) onChanged,
  required Future<void> Function(Map<String, int?> colors) onColorsChanged,
}) async {
  List<CalendarTeam>? edited;
  List<CalendarTeam> opened = const [];
  Map<String, int?>? editedColors;
  Map<String, int> openedColors = const {};
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => Consumer(
      builder: (context, ref, _) {
        final chosen = ref.watch(myCalendarTeamsProvider).value ?? const [];
        opened = chosen;
        final colors = ref.watch(myTeamColorsProvider).value ?? const {};
        openedColors = colors;
        final secondaryEnabled =
            ref.watch(myCalendarLinkProvider).value?.secondaryEnabled ?? false;
        final names = {
          ...ref.watch(ourTeamsProvider),
          for (final t in chosen) t.team,
        }.toList()..sort(compareCzech);
        return _CalendarTeamsList(
          teams: names,
          chosen: chosen,
          colors: colors,
          secondaryEnabled: secondaryEnabled,
          onEdited: (teams) => edited = teams,
          onColorsEdited: (edits) => editedColors = edits,
        );
      },
    ),
  );
  // Untouched, or fiddled back to where it started: nothing to send —
  // teams and colours are judged independently, since they now save
  // separately.
  final teamsChanged = edited != null && !sameTeamChoices(opened, edited!);
  final colorsChanged = editedColors != null &&
      editedColors!.entries.any((e) => openedColors[e.key] != e.value);
  if (!teamsChanged && !colorsChanged) return;
  if (!context.mounted) return;
  await tryAction(
    context,
    () async {
      if (teamsChanged) await onChanged(edited!);
      if (colorsChanged) {
        await onColorsChanged({
          for (final e in editedColors!.entries)
            if (openedColors[e.key] != e.value) e.key: e.value,
        });
      }
    },
    errorText: friendlyDbError,
  );
}

/// Whether two team lists say the same thing — order included, since both
/// sides are kept Czech-sorted.
bool sameTeamChoices(List<CalendarTeam> a, List<CalendarTeam> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].team != b[i].team || a[i].calendar != b[i].calendar) {
      return false;
    }
  }
  return true;
}

/// The list itself, with a local ticked-map overlay on top of [chosen] —
/// same reasoning as `showTeamPickerSheet`'s `_TeamPickerList`, except each
/// entry carries a whole [CalendarTeam] (team + calendar), not just a name,
/// so a tap must show its result right away without losing what the OTHER
/// rows already hold. Colour is a separate overlay again ([_colorEdits]):
/// it lives in a different table now and is never part of [CalendarTeam].
class _CalendarTeamsList extends StatefulWidget {
  const _CalendarTeamsList({
    required this.teams,
    required this.chosen,
    required this.colors,
    required this.secondaryEnabled,
    required this.onEdited,
    required this.onColorsEdited,
  });

  final List<String> teams;
  final List<CalendarTeam> chosen;

  /// The shared per-team colour registry (`team_colors`, 0036) — every
  /// coloured team the player has, not just the ones ticked here.
  final Map<String, int> colors;
  final bool secondaryEnabled;

  /// Reports the full list after every change; the caller sends the last one
  /// it heard once the sheet is closed.
  final void Function(List<CalendarTeam> teams) onEdited;

  /// Reports every colour CHANGE so far (team -> new colorId, or null for
  /// "bez barvy"); a team whose colour was never touched this session is
  /// simply absent. [showCalendarTeamsSheet] diffs this against [colors]
  /// once the sheet closes, so picking a colour back to what it already was
  /// sends nothing.
  final void Function(Map<String, int?> edits) onColorsEdited;

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

  /// Colour EDITS only (a diff over [_CalendarTeamsList.colors]) — see the
  /// field doc on [_CalendarTeamsList.onColorsEdited]. Never resynced from
  /// upstream in [didUpdateWidget]: an explicit pick always wins, same
  /// reasoning as [_edited] for ticks.
  final Map<String, int?> _colorEdits = {};

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
      if (other == null || other.calendar != t.calendar) {
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
    setState(() => _colorEdits[team] = colorId);
    widget.onColorsEdited({..._colorEdits});
  }

  void _setCalendar(String team, CalendarSlot slot) {
    final current = _ticked[team];
    if (current == null) return;
    _replace(team, CalendarTeam(team: team, calendar: slot));
  }

  /// The colour to show for [team]: a local pick if there is one, else
  /// whatever the shared registry already holds.
  int? _colorOf(String team) =>
      _colorEdits.containsKey(team) ? _colorEdits[team] : widget.colors[team];

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
            padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              'Vyber svůj tým — jeho domácí i venkovní zápasy se '
              'přidají do kalendáře.',
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Barva platí i v Můj přehled.'),
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
                  colorId: _colorOf(team),
                  onTap: () async {
                    final current = _colorOf(team);
                    final picked = await pickEventColor(
                      context,
                      current: current,
                      title: 'Barva – $team',
                    );
                    if (picked != current) _setColor(team, picked);
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
