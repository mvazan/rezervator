/// The assign sheet of Správa → Služby (0050): who works one duty. Every
/// player with a checkbox, those with the fewest duties in the duty's
/// season on top, then Czech-sorted, a divider between the counts;
/// searchable by name or nick without diacritics, each with their count
/// („2×“) so the admin balances while picking. „Uložit a další“ saves and
/// moves straight to the next duty.
library;

import 'package:flutter/material.dart';

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
    today: today,
    save: save,
  ),
);

/// The sheet itself: the players by their count in the duty's season,
/// fewest first, then Czech-sorted, with a divider between the counts.
class DutyAssignSheet extends StatefulWidget {
  const DutyAssignSheet({
    super.key,
    required this.periods,
    required this.index,
    required this.assignments,
    required this.seasons,
    required this.roster,
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
  final Day today;
  final Future<void> Function(String periodId, List<String> userIds) save;

  @override
  State<DutyAssignSheet> createState() => _DutyAssignSheetState();
}

class _DutyAssignSheetState extends State<DutyAssignSheet> {
  final _query = TextEditingController();
  late int _index = widget.index;
  late Set<String> _selected = _savedIds(_period);
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

  static String _fold(String s) => foldDiacritics(s).toLowerCase();

  /// The roster narrowed by the search, name or nick, accent- and
  /// case-insensitive. Hidden ticks stay ticked.
  List<Profile> get _matches {
    final q = _fold(_query.text.trim());
    if (q.isEmpty) return widget.roster;
    return [
      for (final p in widget.roster)
        if (_fold(p.displayName).contains(q) || _fold(p.nick).contains(q)) p,
    ];
  }

  /// Duties per player in [_period]'s season, [_period] itself left out —
  /// what the list sorts by, so a tick never moves a row under the finger.
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

  /// [players] with the fewest [others] first, then Czech-sorted, in
  /// groups of one count each. Not alphabetical nor chronological: the
  /// user asked for this exception, so the least-served get picked first.
  static List<List<Profile>> _groups(
    List<Profile> players,
    Map<String, int> others,
  ) {
    final sorted = [...players]
      ..sort((a, b) {
        final byCount = others[a.id]!.compareTo(others[b.id]!);
        return byCount != 0
            ? byCount
            : compareCzech(a.displayName, b.displayName);
      });
    final groups = <List<Profile>>[];
    for (final p in sorted) {
      if (groups.isEmpty || others[groups.last.first.id] != others[p.id]) {
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
      _query.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final period = _period;
    final others = _otherCounts();
    // Sorted by the other duties, the ticks shown live on top of them.
    int count(Profile p) => others[p.id]! + (_selected.contains(p.id) ? 1 : 0);
    final groups = _groups(_matches, others);
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
