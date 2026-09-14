/// Moje týmy: ONE list of teams, three boxes on each — Přehled, Kalendář,
/// Barva.
///
/// It used to be two sheets in two cards: "Moje týmy" ticked
/// `profiles.followed_teams` (what Můj přehled draws) and "Zápasy v
/// kalendáři", hidden inside the Google card, ticked `calendar_teams` (what
/// Google gets). Two lists of the same names, in two places, and the colour
/// — the one thing that was already shared — shown in both. Whoever set up
/// a team in one of them was as likely as not to find the other empty.
///
/// The lists stay two in the database (they mean different things and the
/// backend routes matches off `calendar_teams` alone); what they no longer
/// are is two screens. A row here says everything about one team: whether
/// it shows up in the app, whether it goes to Google, and what colour it
/// wears in both.
///
/// Two things the layout must hold to:
///  * the boxes sit in FIXED columns, and the colour cell keeps its width
///    even while it is empty — a tick must not shift the row it is in;
///  * which of the two Google calendars a team goes to is a rarity (it
///    needs "Rezervátor 2" turned on at all), so it hides behind a long
///    press instead of taking a column of its own.
///
/// Editing is local and NOTHING is saved until Uložit — see
/// [PickerSheetFrame], which also explains why the sheet cannot be swiped
/// away. On Uložit the three lists go out independently, and only the ones
/// that actually changed: the overview list is a cheap column update, the
/// calendar list an expensive edge-function round trip that rewrites every
/// future match, and the colours their own partial upsert.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config.dart';
import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/collation.dart';
import '../../../domain/models.dart';
import 'event_color_picker.dart';
import 'picker_sheet.dart';

Future<void> showMyTeamsSheet(
  BuildContext context, {
  required Future<void> Function(List<String> teams) onFollowedChanged,
  required Future<void> Function(List<CalendarTeam> teams) onCalendarChanged,
  required Future<void> Function(Map<String, int?> colors) onColorsChanged,
}) async {
  List<String>? editedFollowed;
  List<String> openedFollowed = const [];
  List<CalendarTeam>? editedCalendar;
  List<CalendarTeam> openedCalendar = const [];
  Map<String, int?>? editedColors;
  Map<String, int> openedColors = const {};
  var hasCalendar = false;

  final saved = await showModalBottomSheet<bool>(
    context: context,
    // Uložit is the only way to commit, so the one dismissal that cannot be
    // guarded must not exist — see PickerSheetFrame.
    enableDrag: false,
    builder: (sheetContext) => Consumer(
      builder: (context, ref, _) {
        final profile = ref.watch(myProfileProvider).value;
        final followed = profile?.followedTeams ?? const <String>[];
        final routed = ref.watch(myCalendarTeamsProvider).value ?? const [];
        final colors = ref.watch(myTeamColorsProvider).value ?? const {};
        final link = ref.watch(myCalendarLinkProvider).value ?? CalendarLink.none;
        openedFollowed = followed;
        openedCalendar = routed;
        openedColors = colors;
        // The Kalendář column exists only where the calendar does: no
        // Google client id baked in, the Play-review demo account, or a
        // player who has not linked one — the same gate the card itself
        // uses, so the sheet cannot offer what the app cannot do.
        hasCalendar = ref.watch(calendarAvailableProvider) &&
            !AppConfig.isDemoAccount(profile?.email ?? '') &&
            link.isLinked;
        // Every team the schedule knows plus whatever is already picked in
        // either list — a team that has left the schedule can still be
        // unticked.
        final teams = <String>{
          ...ref.watch(ourTeamsProvider),
          ...followed,
          for (final t in routed) t.team,
        }.toList()
          ..sort(compareCzech);
        return _MyTeamsList(
          teams: teams,
          followed: followed,
          routed: routed,
          colors: colors,
          hasCalendar: hasCalendar,
          secondaryEnabled: link.secondaryEnabled,
          onFollowedEdited: (list) => editedFollowed = list,
          onCalendarEdited: (list) => editedCalendar = list,
          onColorsEdited: (edits) => editedColors = edits,
        );
      },
    ),
  );
  if (saved != true) return;

  // Judged independently — three lists, three calls, and a list ticked back
  // to where it started sends nothing.
  final followedChanged = editedFollowed != null &&
      !_sameNames(openedFollowed, editedFollowed!);
  final calendarChanged = hasCalendar &&
      editedCalendar != null &&
      !sameTeamChoices(openedCalendar, editedCalendar!);
  final colorsChanged = editedColors != null &&
      editedColors!.entries.any((e) => openedColors[e.key] != e.value);
  if (!followedChanged && !calendarChanged && !colorsChanged) return;
  if (!context.mounted) return;
  await tryAction(
    context,
    () async {
      // Cheapest first: the overview is a column on the player's own row,
      // while the calendar list refreshes a Google token and rewrites every
      // future match.
      if (followedChanged) await onFollowedChanged(editedFollowed!);
      if (calendarChanged) await onCalendarChanged(editedCalendar!);
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

/// Whether two name lists hold the same teams — both sides are kept
/// Czech-sorted, so order is part of the answer.
bool _sameNames(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  final left = [...a]..sort(compareCzech);
  for (var i = 0; i < left.length; i++) {
    if (left[i] != b[i]) return false;
  }
  return true;
}

/// Whether two calendar lists say the same thing — team AND calendar,
/// order included, since both sides are kept Czech-sorted.
bool sameTeamChoices(List<CalendarTeam> a, List<CalendarTeam> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].team != b[i].team || a[i].calendar != b[i].calendar) {
      return false;
    }
  }
  return true;
}

/// The list itself, with local overlays on top of what the streams say: a
/// tap must show its result at once, and a second tap that lands before the
/// first one's round trip must not be computed from a now-stale list. The
/// overlays resync to the streams while untouched (a change from another
/// device), and stop listening from the first edit — what the player is
/// doing here wins until they save or leave.
class _MyTeamsList extends StatefulWidget {
  const _MyTeamsList({
    required this.teams,
    required this.followed,
    required this.routed,
    required this.colors,
    required this.hasCalendar,
    required this.secondaryEnabled,
    required this.onFollowedEdited,
    required this.onCalendarEdited,
    required this.onColorsEdited,
  });

  final List<String> teams;

  /// `profiles.followed_teams` — whose matches Můj přehled draws.
  final List<String> followed;

  /// `calendar_teams` — whose matches Google gets, and in which calendar.
  final List<CalendarTeam> routed;

  /// The shared per-team colour registry (`team_colors`, 0036) — every
  /// coloured team the player has, ticked here or not.
  final Map<String, int> colors;

  /// False hides the Kalendář column outright.
  final bool hasCalendar;

  /// "Rezervátor 2" is on: a team in the calendar can be sent to either one
  /// (long press), and the row says which.
  final bool secondaryEnabled;

  final void Function(List<String> teams) onFollowedEdited;
  final void Function(List<CalendarTeam> teams) onCalendarEdited;

  /// Reports every colour CHANGE so far (team -> new colorId, or null for
  /// "bez barvy"); a team whose colour was never touched is simply absent.
  /// [showMyTeamsSheet] diffs this against [colors] on Uložit.
  final void Function(Map<String, int?> edits) onColorsEdited;

  @override
  State<_MyTeamsList> createState() => _MyTeamsListState();
}

class _MyTeamsListState extends State<_MyTeamsList> {
  /// One column's worth of row: a 48dp touch target with air around it, and
  /// wide enough for its heading. Every cell is this wide whatever is in
  /// it — including nothing, which is the point.
  static const _cell = 56.0;
  static const _rowHeight = 56.0;

  late Set<String> _followed = widget.followed.toSet();
  late Map<String, CalendarTeam> _routed = {
    for (final t in widget.routed) t.team: t,
  };
  final Map<String, int?> _colorEdits = {};

  /// Set by the first edit of that list: from then on the player owns it,
  /// not the stream underneath.
  bool _editedFollowed = false;
  bool _editedRouted = false;

  @override
  void didUpdateWidget(_MyTeamsList old) {
    super.didUpdateWidget(old);
    if (!_editedFollowed && !_sameSet(old.followed, widget.followed)) {
      _followed = widget.followed.toSet();
    }
    if (!_editedRouted && !_sameRouting(old.routed, widget.routed)) {
      _routed = {for (final t in widget.routed) t.team: t};
    }
  }

  static bool _sameSet(List<String> a, List<String> b) =>
      a.length == b.length && a.toSet().containsAll(b);

  static bool _sameRouting(List<CalendarTeam> a, List<CalendarTeam> b) {
    if (a.length != b.length) return false;
    final byName = {for (final t in a) t.team: t};
    for (final t in b) {
      if (byName[t.team]?.calendar != t.calendar) return false;
    }
    return true;
  }

  List<CalendarTeam> _sortedRouted() =>
      _routed.values.toList()..sort((a, b) => compareCzech(a.team, b.team));

  void _toggleFollowed(String team, bool on) {
    setState(() {
      _editedFollowed = true;
      on ? _followed.add(team) : _followed.remove(team);
    });
    widget.onFollowedEdited(_followed.toList()..sort(compareCzech));
  }

  /// Replaces [team]'s calendar row with [next] (drops it when null).
  void _replaceRouted(String team, CalendarTeam? next) {
    setState(() {
      _editedRouted = true;
      if (next == null) {
        _routed.remove(team);
      } else {
        _routed[team] = next;
      }
    });
    widget.onCalendarEdited(_sortedRouted());
  }

  void _setColor(String team, int? colorId) {
    setState(() => _colorEdits[team] = colorId);
    widget.onColorsEdited({..._colorEdits});
  }

  /// The colour to show for [team]: a local pick if there is one, else
  /// whatever the shared registry already holds.
  int? _colorOf(String team) =>
      _colorEdits.containsKey(team) ? _colorEdits[team] : widget.colors[team];

  /// Which of the two Google calendars this team's matches go to. Only
  /// reachable while "Rezervátor 2" is on and the team is in the calendar
  /// at all — otherwise there is nothing to choose between.
  Future<void> _pickCalendar(String team, CalendarTeam entry) async {
    final picked = await showModalBottomSheet<(CalendarSlot?,)>(
      context: context,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(
                'Zápasy — $team',
                style: Theme.of(sheet).textTheme.titleMedium,
              ),
              subtitle: const Text('Do kterého kalendáře patří.'),
            ),
            RadioGroup<CalendarSlot>(
              groupValue: entry.calendar,
              onChanged: (v) => Navigator.of(sheet).pop((v,)),
              child: const Column(
                children: [
                  RadioListTile<CalendarSlot>(
                    value: CalendarSlot.primary,
                    title: Text('Hlavní kalendář'),
                  ),
                  RadioListTile<CalendarSlot>(
                    value: CalendarSlot.secondary,
                    title: Text('Druhý kalendář'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final slot = picked?.$1;
    if (slot != null && slot != entry.calendar) {
      _replaceRouted(team, CalendarTeam(team: team, calendar: slot));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PickerSheetFrame(
      title: 'Moje týmy',
      dirty: _editedFollowed || _editedRouted || _colorEdits.isNotEmpty,
      hints: [
        if (widget.hasCalendar)
          'Přehled = Můj přehled v appce, Kalendář = Google kalendář.'
        else
          'Zaškrtni týmy, jejichž zápasy chceš vidět v Můj přehled.',
        if (widget.hasCalendar && widget.secondaryEnabled)
          'Podržením týmu vybereš, do kterého kalendáře jeho zápasy patří.',
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _headings(context),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                if (widget.teams.isEmpty)
                  const ListTile(
                    leading: Icon(Icons.emoji_events_outlined),
                    title: Text('Zatím žádné zápasy v rozvrhu'),
                  ),
                for (final team in widget.teams) _teamRow(team),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// What the columns are, said once instead of on every row.
  Widget _headings(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );
    Widget heading(String text) => SizedBox(
          width: _cell,
          child: Text(
            text,
            style: style,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
      child: Row(
        children: [
          const Spacer(),
          heading('Přehled'),
          if (widget.hasCalendar) heading('Kalendář'),
          heading('Barva'),
        ],
      ),
    );
  }

  Widget _teamRow(String team) {
    final followed = _followed.contains(team);
    final entry = _routed[team];
    // A colour is worth picking once the team is somewhere to be seen —
    // and only somewhere this row SHOWS. Without the Kalendář column a
    // calendar-only team is a dot beside nothing ticked, which reads as a
    // bug rather than as a colour.
    final coloured = followed || (widget.hasCalendar && entry != null);
    final routable = widget.hasCalendar && widget.secondaryEnabled;
    return InkWell(
      key: ValueKey(team),
      onLongPress:
          routable && entry != null ? () => _pickCalendar(team, entry) : null,
      child: SizedBox(
        height: _rowHeight,
        child: Row(
          children: [
            const SizedBox(width: 16),
            Expanded(
              child: Text(team, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            _cellBox(
              key: ValueKey('$team:overview'),
              child: Checkbox(
                value: followed,
                onChanged: (on) => _toggleFollowed(team, on == true),
              ),
            ),
            if (widget.hasCalendar)
              _cellBox(
                key: ValueKey('$team:calendar'),
                child: _calendarBox(team, entry),
              ),
            _cellBox(
              key: ValueKey('$team:color'),
              // Empty, but the same width as ever: a tick two columns to
              // the left must not move anything.
              child: !coloured
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
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  /// The Kalendář tick, with a quiet "2" when the team's matches go to the
  /// second calendar — a badge rather than a row of its own, so turning it
  /// on does not make the row taller.
  Widget _calendarBox(String team, CalendarTeam? entry) {
    final checkbox = Checkbox(
      value: entry != null,
      onChanged: (on) =>
          _replaceRouted(team, on == true ? CalendarTeam(team: team) : null),
    );
    if (entry?.calendar != CalendarSlot.secondary) return checkbox;
    return Stack(
      alignment: Alignment.center,
      children: [
        checkbox,
        Positioned(
          right: 2,
          bottom: 6,
          child: Tooltip(
            message: 'Druhý kalendář',
            child: Text(
              '2',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _cellBox({required Key key, Widget? child}) => SizedBox(
        key: key,
        width: _cell,
        child: Center(child: child ?? const SizedBox.shrink()),
      );
}
