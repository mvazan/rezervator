import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/collation.dart';

/// The checkbox sheet both the calendar card and the Moje týmy card open:
/// every team the schedule knows (home team of a home match, away team of
/// an away match) plus whatever is already chosen, so a team that vanished
/// from the schedule can still be unticked. Each toggle is saved at once by
/// [onChanged]; the chosen list is re-read through [chosenOf] on every
/// build, so the sheet follows the same stream the card watches.
Future<void> showTeamPickerSheet(
  BuildContext context, {
  required String title,
  required String hint,
  required List<String> Function(WidgetRef ref) chosenOf,
  required Future<void> Function(List<String> teams) onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => Consumer(
      builder: (context, ref, _) {
        final chosen = chosenOf(ref);
        final teams = {...ref.watch(ourTeamsProvider), ...chosen}.toList()
          ..sort(compareCzech);
        return _TeamPickerList(
          title: title,
          hint: hint,
          teams: teams,
          chosen: chosen,
          onChanged: onChanged,
        );
      },
    ),
  );
}

/// The list itself, with a local ticked-set overlay on top of [chosen]: a
/// tap must show its checkmark right away, and a second tap that lands
/// before the first one's realtime round trip returns must not be computed
/// from the now-stale [chosen] and so lose the first — both would happen if
/// the ticked set were only ever [chosen] re-read from the provider. The
/// overlay still re-syncs to [chosen] whenever it actually changes (the
/// save landing, or a change from another device), so the sheet never
/// drifts from the backend for long.
class _TeamPickerList extends StatefulWidget {
  const _TeamPickerList({
    required this.title,
    required this.hint,
    required this.teams,
    required this.chosen,
    required this.onChanged,
  });

  final String title;
  final String hint;
  final List<String> teams;
  final List<String> chosen;
  final Future<void> Function(List<String> teams) onChanged;

  @override
  State<_TeamPickerList> createState() => _TeamPickerListState();
}

class _TeamPickerListState extends State<_TeamPickerList> {
  late Set<String> _ticked = widget.chosen.toSet();

  /// The newest list waiting to go out, and whether one is already on its
  /// way. Every save carries the WHOLE list, so a tick made while another
  /// save is in the air replaces what is waiting instead of queueing behind
  /// it — and the send outlives the sheet, so closing it right after a tick
  /// does not throw that tick away. Same shape as showCalendarTeamsSheet.
  List<String>? _next;
  bool _sending = false;

  @override
  void didUpdateWidget(_TeamPickerList old) {
    super.didUpdateWidget(old);
    // Only a genuine change from upstream resyncs the overlay, and only while
    // no save is in flight — a rebuild triggered by something else (e.g. the
    // schedule changing) or the row of an older save arriving mid-queue must
    // not clobber a tap that is still on its way.
    if (!_sending && _next == null && !_sameTeams(old.chosen, widget.chosen)) {
      _ticked = widget.chosen.toSet();
    }
  }

  static bool _sameTeams(List<String> a, List<String> b) =>
      a.length == b.length && a.toSet().containsAll(b);

  void _toggle(String team, bool on) {
    setState(() => on ? _ticked.add(team) : _ticked.remove(team));
    _next = _ticked.toList()..sort(compareCzech);
    _pump();
  }

  /// Sends the newest list, then whatever arrived while that was in the air.
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
      // One save now covers every tick made while it waited, so a failure
      // rolls the whole list back to what the server last confirmed rather
      // than undoing a single box.
      if (!saved && mounted && _next == null) {
        setState(() => _ticked = widget.chosen.toSet());
      }
    }
    _sending = false;
  }

  /// The sheet is gone, so there is nobody to show a snack to — but the tick
  /// the player made before closing it still deserves to land.
  Future<bool> _sendDetached(
    Future<void> Function(List<String>) onChanged,
    List<String> snapshot,
  ) async {
    try {
      await onChanged(snapshot);
      return true;
    } catch (error) {
      debugPrint('followed teams save after the sheet closed failed: $error');
      return false;
    }
  }

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
          for (final team in widget.teams)
            CheckboxListTile(
              value: _ticked.contains(team),
              title: Text(team),
              onChanged: (on) => _toggle(team, on == true),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
