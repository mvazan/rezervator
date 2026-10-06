/// The assign sheet of Správa → Služby (0050): who works one duty. Every
/// player with a checkbox, those with the fewest duties in the duty's
/// season on top, then Czech-sorted, a divider between the counts;
/// narrowed by club (oddíl) with chips, searchable by name or nick without
/// diacritics, each with their count
/// („2×“) so the admin balances while picking. „Uložit a další“ saves and
/// moves straight to the next duty.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/local_prefs.dart';
import '../../../core/ui.dart';
import '../../../domain/collation.dart';
import '../../../domain/duties.dart';
import '../../../domain/models.dart';

/// Opens the sheet on [periods]`[index]`; resolves to true when it saved
/// anything before „Uložit“ closed it (the caller says so), false when
/// nothing changed, null when dismissed. [periods] are
/// chronological — „Uložit a další“ walks them in that order.
Future<bool?> showDutyAssignSheet(
  BuildContext context, {
  required List<DutyPeriod> periods,
  required int index,
  required List<DutyAssignment> assignments,
  required List<DutySeason> seasons,
  required List<Profile> roster,
  List<Club> clubs = const [],
  required Day today,
  required Future<void> Function(String periodId, List<String> userIds) save,
}) => showModalBottomSheet<bool>(
  context: context,
  isScrollControlled: true,
  builder: (_) => DutyAssignSheet(
    periods: periods,
    index: index,
    assignments: assignments,
    seasons: seasons,
    roster: roster,
    clubs: clubs,
    today: today,
    save: save,
  ),
);

/// The sheet itself: the players by their count in the duty's season,
/// fewest first, then Czech-sorted, with a divider between the counts.
class DutyAssignSheet extends ConsumerStatefulWidget {
  const DutyAssignSheet({
    super.key,
    required this.periods,
    required this.index,
    required this.assignments,
    required this.seasons,
    required this.roster,
    this.clubs = const [],
    required this.today,
    required this.save,
  });

  /// Every period, chronological.
  final List<DutyPeriod> periods;

  /// Which of [periods] the sheet opens on.
  final int index;
  final List<DutyAssignment> assignments;
  final List<DutySeason> seasons;

  /// The players to offer (`dutyRoster`), Czech-sorted — the order a save
  /// sends them in; the list sorts by count first.
  final List<Profile> roster;

  /// The alley's clubs, for the filter chips; only those with a player in
  /// [roster] get one.
  final List<Club> clubs;
  final Day today;
  final Future<void> Function(String periodId, List<String> userIds) save;

  @override
  ConsumerState<DutyAssignSheet> createState() => _DutyAssignSheetState();
}

class _DutyAssignSheetState extends ConsumerState<DutyAssignSheet> {
  final _query = TextEditingController();
  late int _index = widget.index;
  late Set<String> _selected = _savedIds(_period);

  static const _noClub = '';

  /// The club the list is narrowed to: null = everybody, [_noClub] = the
  /// players without one. Remembered on the device (the next duty, the next
  /// opening), unless that club has no chip any more. Hidden ticks stay
  /// ticked.
  String? get _club {
    final saved = ref.watch(dutyClubFilterProvider);
    if (saved == null) return null;
    final chips = _chips;
    return chips.any((c) => c.$1 == saved) ? saved : null;
  }

  /// What the list sorts by: [_savedCounts] as the sheet reached
  /// [_period], kept until it moves on, so a tick never moves a row
  /// under the finger.
  late Map<String, int> _order = _savedCounts();
  bool _saving = false;

  /// What this sheet saved, per period: the streams catch up a moment
  /// later, and the counts of the next duty must include it already.
  final _saved = <String, Set<String>>{};

  DutyPeriod get _period => widget.periods[_index];

  bool get _hasNext => _index + 1 < widget.periods.length;

  /// The assignments as they stand after this sheet's saves.
  List<DutyAssignment> get _assignments => [
    for (final a in widget.assignments)
      if (!_saved.containsKey(a.periodId)) a,
    for (final MapEntry(key: periodId, value: ids) in _saved.entries)
      for (final id in ids) DutyAssignment(periodId: periodId, userId: id),
  ];

  Set<String> _savedIds(DutyPeriod period) =>
      assigneeIds(_assignments, period.id).toSet();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// The clubs with a player in the roster, Czech-sorted — a club nobody
  /// of the roster belongs to would be a chip to an empty list.
  List<Club> get _chipClubs {
    final used = {for (final p in widget.roster) p.clubId};
    return [
      for (final c in widget.clubs)
        if (used.contains(c.id)) c,
    ]..sort((a, b) => compareCzech(a.name, b.name));
  }

  /// Whether some player of the roster has no club (or a deleted one).
  bool get _hasNoClub {
    final known = {for (final c in widget.clubs) c.id};
    return widget.roster.any((p) => !known.contains(p.clubId));
  }

  bool _inClub(Profile p) {
    final club = _club;
    if (club == null) return true;
    if (club == _noClub) {
      return !widget.clubs.any((c) => c.id == p.clubId);
    }
    return p.clubId == club;
  }

  /// The roster narrowed by the club and the search, by words of the name
  /// and the nick, accent- and case-insensitive. Hidden ticks stay ticked.
  List<Profile> get _matches => [
    for (final p in widget.roster)
      if (_inClub(p) &&
          matchesWordsAcross([p.displayName, p.nick], _query.text))
        p,
  ];

  /// „Všichni“ and a chip per club; empty when there is nothing to choose
  /// between (one club or none).
  List<(String?, String)> get _chips {
    final clubs = _chipClubs;
    final chips = <(String?, String)>[
      (null, 'Všichni'),
      for (final c in clubs) (c.id, c.name),
      if (clubs.isNotEmpty && _hasNoClub) (_noClub, 'Bez oddílu'),
    ];
    return chips.length < 3 ? const [] : chips;
  }

  /// The chips in one row that scrolls sideways when the clubs outgrow the
  /// sheet.
  Widget _clubChips() {
    final chips = _chips;
    if (chips.isEmpty) return const SizedBox.shrink();
    final selected = _club;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            for (final (i, (id, label)) in chips.indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              ChoiceChip(
                label: Text(label),
                selected: selected == id,
                onSelected: (_) =>
                    ref.read(dutyClubFilterProvider.notifier).set(id),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Duties per player in [_period]'s season, [_period] itself left out;
  /// the ticks go on top of them.
  Map<String, int> _otherCounts() {
    final period = _period;
    final season = seasonRanges(
      widget.seasons,
    ).firstWhere((s) => s.containsPeriod(period));
    final others = dutyCounts(
      widget.periods,
      [
        for (final a in _assignments)
          if (a.periodId != period.id) a,
      ],
      season,
      today: widget.today,
    );
    return {for (final p in widget.roster) p.id: others[p.id]?.duties ?? 0};
  }

  /// Duties per player in [_period]'s season with [_period]'s saved
  /// assignees in — the counts the rows show until something is ticked.
  Map<String, int> _savedCounts() {
    final saved = _savedIds(_period);
    return {
      for (final MapEntry(key: id, value: n) in _otherCounts().entries)
        id: n + (saved.contains(id) ? 1 : 0),
    };
  }

  /// [players] with the fewest [counts] first, then Czech-sorted, in
  /// groups of one count each. Neither alphabetical nor chronological: the
  /// user asked for this exception, so the least-served get picked first.
  static List<List<Profile>> _groups(
    List<Profile> players,
    Map<String, int> counts,
  ) {
    // Defensive: the roster is fixed for the sheet's lifetime, so every
    // player has a count; a missing one would read as none served.
    int count(Profile p) => counts[p.id] ?? 0;
    final sorted = [...players]
      ..sort((a, b) {
        final byCount = count(a).compareTo(count(b));
        return byCount != 0
            ? byCount
            : compareCzech(a.displayName, b.displayName);
      });
    final groups = <List<Profile>>[];
    for (final p in sorted) {
      if (groups.isEmpty || count(groups.last.first) != count(p)) {
        groups.add([]);
      }
      groups.last.add(p);
    }
    return groups;
  }

  /// Saves the ticks (skipped when nothing changed); true when done.
  Future<bool> _store() async {
    final period = _period;
    final before = _savedIds(period);
    if (_selected.length == before.length && _selected.containsAll(before)) {
      return true;
    }
    // In the roster's order, so the call reads like the list.
    final ids = [
      for (final p in widget.roster)
        if (_selected.contains(p.id)) p.id,
    ];
    setState(() => _saving = true);
    final ok = await tryAction(
      context,
      () => widget.save(period.id, ids),
      errorText: friendlyDbError,
    );
    if (!mounted) return false;
    setState(() {
      _saving = false;
      if (ok) _saved[period.id] = ids.toSet();
    });
    return ok;
  }

  /// Pops whether anything was saved on the way — „Uloženo.“ only then.
  Future<void> _saveAndClose() async {
    if (await _store() && mounted) {
      Navigator.of(context).pop(_saved.isNotEmpty);
    }
  }

  Future<void> _saveAndNext() async {
    if (!await _store() || !mounted) return;
    setState(() {
      _index++;
      _selected = _savedIds(_period);
      _order = _savedCounts();
      _query.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final period = _period;
    final others = _otherCounts();
    // Sorted by the saved duties, the ticks shown live on top of the others.
    int count(Profile p) => others[p.id]! + (_selected.contains(p.id) ? 1 : 0);
    final groups = _groups(_matches, _order);
    final title = period.note.isEmpty
        ? dutyRangeLabel(period)
        : '${dutyRangeLabel(period)} · ${period.note}';
    return Padding(
      // Keeps the list above the keyboard while searching.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(title, style: theme.textTheme.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _query,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'jméno nebo přezdívka',
                  ),
                ),
              ),
              _clubChips(),
              const SizedBox(height: 8),
              Flexible(
                child: groups.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Nikdo neodpovídá hledání.'),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final (i, group) in groups.indexed) ...[
                            if (i > 0) const Divider(),
                            for (final p in group) _tile(p, count(p)),
                          ],
                        ],
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (_hasNext)
                      OutlinedButton(
                        onPressed: _saving ? null : _saveAndNext,
                        child: const Text('Uložit a další'),
                      ),
                    FilledButton(
                      onPressed: _saving ? null : _saveAndClose,
                      child: const Text('Uložit'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One player's row: the tick, the name and [count] with the tick in.
  Widget _tile(Profile p, int count) => CheckboxListTile(
    controlAffinity: ListTileControlAffinity.leading,
    value: _selected.contains(p.id),
    onChanged: _saving
        ? null
        : (on) => setState(() {
            if (on == true) {
              _selected.add(p.id);
            } else {
              _selected.remove(p.id);
            }
          }),
    title: Text(p.displayName),
    subtitle: _subtitle(p),
    // The slot sets no text style of its own.
    secondary: Text('$count×', style: Theme.of(context).textTheme.titleSmall),
  );

  /// What tells a player apart: no account, the board nick.
  Widget? _subtitle(Profile p) {
    final parts = [
      if (!p.hasAccount) 'bez účtu',
      if (p.nick.isNotEmpty) '„${p.nick}“',
    ];
    return parts.isEmpty ? null : Text(parts.join(' · '));
  }
}
