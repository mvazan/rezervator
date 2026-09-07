import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/collation.dart';
import 'event_color_picker.dart';

/// Moje týmy: the checkbox sheet `my_teams_card.dart` opens — every team the
/// schedule knows (home team of a home match, away team of an away match)
/// plus whatever is already chosen, so a team that vanished from the
/// schedule can still be unticked. A ticked team also carries a colour dot
/// (`EventColorPicker`, the same one `showCalendarTeamsSheet` uses) onto a
/// SHARED registry (`team_colors`, 0036) — the colour picked here is the
/// same one shown on the Google Calendar event, and vice versa; it survives
/// even after the team is unticked here, since following and colouring a
/// team are independent.
///
/// Editing is local; the whole tick list is saved at once by [onChanged],
/// exactly as before this feature existed, and any changed colour goes out
/// alongside it through [onColorsChanged] — its own call, only when a
/// colour actually changed. The chosen list and colours are re-read through
/// [chosenOf]/[colorsOf] on every build, so the sheet follows the same
/// streams the card watches.
Future<void> showTeamPickerSheet(
  BuildContext context, {
  required String title,
  required String hint,
  required List<String> Function(WidgetRef ref) chosenOf,
  required Future<void> Function(List<String> teams) onChanged,
  required Map<String, int> Function(WidgetRef ref) colorsOf,
  required Future<void> Function(Map<String, int?> colors) onColorsChanged,
}) async {
  List<String>? edited;
  List<String> opened = const [];
  Map<String, int?>? editedColors;
  Map<String, int> openedColors = const {};
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => Consumer(
      builder: (context, ref, _) {
        final chosen = chosenOf(ref);
        opened = chosen;
        final colors = colorsOf(ref);
        openedColors = colors;
        final teams = {...ref.watch(ourTeamsProvider), ...chosen}.toList()
          ..sort(compareCzech);
        return _TeamPickerList(
          title: title,
          hint: hint,
          teams: teams,
          chosen: chosen,
          colors: colors,
          onEdited: (list) => edited = list,
          onColorsEdited: (edits) => editedColors = edits,
        );
      },
    ),
  );
  final before = [...opened]..sort(compareCzech);
  // Untouched, or ticked back to where it started: nothing to send — teams
  // and colours are judged independently, since they now save separately
  // (through onChanged and onColorsChanged respectively).
  final teamsChanged = edited != null &&
      !(before.length == edited!.length &&
          List.generate(before.length, (i) => before[i] == edited![i])
              .every((same) => same));
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

/// The list itself, with a local ticked-set overlay on top of [chosen]: a
/// tap must show its checkmark right away, and a second tap that lands
/// before the first one's realtime round trip returns must not be computed
/// from the now-stale [chosen] and so lose the first — both would happen if
/// the ticked set were only ever [chosen] re-read from the provider. The
/// overlay still re-syncs to [chosen] whenever it actually changes (the
/// save landing, or a change from another device), so the sheet never
/// drifts from the backend for long. Colour is a separate overlay again
/// ([_colorEdits]): it lives in a different table, keyed only by team name,
/// not by whether the team is ticked here at all.
class _TeamPickerList extends StatefulWidget {
  const _TeamPickerList({
    required this.title,
    required this.hint,
    required this.teams,
    required this.chosen,
    required this.colors,
    required this.onEdited,
    required this.onColorsEdited,
  });

  final String title;
  final String hint;
  final List<String> teams;
  final List<String> chosen;

  /// The shared per-team colour registry (`team_colors`, 0036) — every
  /// coloured team the player has, not just the followed ones.
  final Map<String, int> colors;

  /// Reports the full list after every tick; the caller sends the last one
  /// it heard once the sheet is closed.
  final void Function(List<String> teams) onEdited;

  /// Reports every colour CHANGE so far (team -> new colorId, or null for
  /// "bez barvy"); a team whose colour was never touched this session is
  /// simply absent. [showTeamPickerSheet] diffs this against [colors] once
  /// the sheet closes, so picking a colour back to what it already was
  /// sends nothing.
  final void Function(Map<String, int?> edits) onColorsEdited;

  @override
  State<_TeamPickerList> createState() => _TeamPickerListState();
}

class _TeamPickerListState extends State<_TeamPickerList> {
  late Set<String> _ticked = widget.chosen.toSet();

  /// Set by the first tick: from then on the player's edits own the list,
  /// not the stream underneath it.
  bool _edited = false;

  /// Colour EDITS only (a diff over [_TeamPickerList.colors]) — see the
  /// field doc on [_TeamPickerList.onColorsEdited]. Never resynced from
  /// upstream in [didUpdateWidget]: an explicit pick always wins, same
  /// reasoning as [_edited] for ticks.
  final Map<String, int?> _colorEdits = {};

  @override
  void didUpdateWidget(_TeamPickerList old) {
    super.didUpdateWidget(old);
    // Only a genuine change from upstream resyncs the overlay, and only while
    // no save is in flight — a rebuild triggered by something else (e.g. the
    // schedule changing) or the row of an older save arriving mid-queue must
    // not clobber a tap that is still on its way.
    if (!_edited && !_sameTeams(old.chosen, widget.chosen)) {
      _ticked = widget.chosen.toSet();
    }
  }

  static bool _sameTeams(List<String> a, List<String> b) =>
      a.length == b.length && a.toSet().containsAll(b);

  /// Local only — the whole list goes out once, when the sheet closes.
  void _toggle(String team, bool on) {
    setState(() {
      _edited = true;
      on ? _ticked.add(team) : _ticked.remove(team);
    });
    widget.onEdited(_ticked.toList()..sort(compareCzech));
  }

  void _setColor(String team, int? colorId) {
    setState(() => _colorEdits[team] = colorId);
    widget.onColorsEdited({..._colorEdits});
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
            child: Text(widget.title,
                style: Theme.of(context).textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(widget.hint),
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
    final ticked = _ticked.contains(team);
    return ListTile(
      key: ValueKey(team),
      leading: Checkbox(
        value: ticked,
        onChanged: (on) => _toggle(team, on == true),
      ),
      title: Text(team),
      // Unticked, the row itself is a bigger target for turning it on;
      // ticked, the row also hosts the colour dot, so only the checkbox
      // turns it back off — same reasoning `showCalendarTeamsSheet` follows.
      onTap: ticked ? null : () => _toggle(team, true),
      trailing: !ticked
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
    );
  }
}
