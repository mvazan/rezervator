import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/models.dart';

/// Removing a day block that still has sign-ups: the admin drags each
/// reservation from the removed block (left) onto a lane of one of the
/// blocks it was covering (right — they resurface after the removal).
/// Committing performs the staged moves via the move_reservation RPC and
/// resolves `true`; anything left unmoved is cancelled by the subsequent
/// override write (confirmed here first). `false`/dismiss = abort removal.
class MoveReservationsDialog extends ConsumerStatefulWidget {
  const MoveReservationsDialog({
    super.key,
    required this.date,
    required this.fromBlock,
    required this.targets,
    required this.cancelNote,
  });

  final Day date;
  final TimeBlock fromBlock;

  /// Blocks overlapped by [fromBlock] — the homes a reservation can move to.
  final List<TimeBlock> targets;

  /// The note unmoved reservations will carry once cancelled.
  final String cancelNote;

  @override
  ConsumerState<MoveReservationsDialog> createState() =>
      _MoveReservationsDialogState();
}

class _MoveReservationsDialogState
    extends ConsumerState<MoveReservationsDialog> {
  /// reservation id → staged new home.
  final _staged = <String, (TimeBlock, int lane)>{};
  bool _committing = false;

  Day get _monday => widget.date.addDays(1 - widget.date.weekday);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final laneCount =
        (ref.watch(settingsProvider).value ?? ScheduleSettings.defaults)
            .laneCount;
    final reservations =
        ref.watch(weekReservationsProvider(_monday)).value ?? const [];
    final players = ref.watch(playersProvider).value ?? const [];
    final nameById = {
      for (final p in players)
        p.id: p.nick.isNotEmpty ? p.nick : p.displayName,
    };

    final toMove = [
      for (final r in reservations)
        if (r.isLive &&
            r.date == widget.date &&
            r.blockId == widget.fromBlock.id)
          r,
    ]..sort((a, b) => a.lane.compareTo(b.lane));
    final unmoved = [
      for (final r in toMove)
        if (!_staged.containsKey(r.id)) r,
    ];

    bool laneTaken(TimeBlock block, int lane) =>
        reservations.any((r) =>
            r.isLive &&
            r.date == widget.date &&
            r.blockId == block.id &&
            r.lane == lane) ||
        _staged.values.any((s) => s.$1.id == block.id && s.$2 == lane);

    Widget chip(Reservation r, {bool staged = false}) => Chip(
          label: Text(
            '${nameById[r.playerId] ?? '?'} · D${r.lane}',
            style: const TextStyle(fontSize: 12),
          ),
          backgroundColor:
              staged ? scheme.secondaryContainer : scheme.primaryContainer,
          visualDensity: VisualDensity.compact,
        );

    return AlertDialog(
      title: Text('Přesun rezervací — ${dayFull(widget.date)}'),
      content: SizedBox(
        width: 600,
        height: 420,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // LEFT: the removed block and its still-unmoved sign-ups.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Rušený blok ${widget.fromBlock.label}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final r in unmoved)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Draggable<Reservation>(
                              data: r,
                              feedback: Material(
                                color: Colors.transparent,
                                child: chip(r),
                              ),
                              childWhenDragging: Opacity(
                                opacity: 0.3,
                                child: chip(r),
                              ),
                              child: chip(r),
                            ),
                          ),
                        if (unmoved.isEmpty)
                          Text(
                            'Vše přesunuto.',
                            style:
                                TextStyle(color: scheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                  if (unmoved.isNotEmpty)
                    Text(
                      'Nepřesunuté rezervace budou zrušeny.',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.error,
                      ),
                    ),
                ],
              ),
            ),
            const VerticalDivider(width: 24),
            // RIGHT: the resurfacing blocks, one drop target per lane.
            Expanded(
              child: ListView(
                children: [
                  for (final target in widget.targets) ...[
                    Text(
                      'Blok ${target.label}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    for (var lane = 1; lane <= laneCount; lane++)
                      _laneTarget(context, scheme, target, lane,
                          laneTaken(target, lane), nameById),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _committing ? null : () => Navigator.of(context).pop(false),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: _committing
              ? null
              : () => _commit(unmovedCount: unmoved.length),
          child: Text(_committing ? 'Přesouvám…' : 'Pokračovat'),
        ),
      ],
    );
  }

  Widget _laneTarget(
    BuildContext context,
    ColorScheme scheme,
    TimeBlock block,
    int lane,
    bool taken,
    Map<String, String> nameById,
  ) {
    // The occupant label: a live reservation already there, or a staged one.
    String? occupant;
    final stagedEntry = _staged.entries
        .where((e) => e.value.$1.id == block.id && e.value.$2 == lane)
        .toList();
    if (stagedEntry.isNotEmpty) {
      final reservations =
          ref.read(weekReservationsProvider(_monday)).value ?? const [];
      final r = reservations
          .where((r) => r.id == stagedEntry.first.key)
          .toList();
      occupant = r.isEmpty ? '?' : (nameById[r.first.playerId] ?? '?');
    } else if (taken) {
      final reservations =
          ref.read(weekReservationsProvider(_monday)).value ?? const [];
      final r = reservations
          .where((r) =>
              r.isLive &&
              r.date == widget.date &&
              r.blockId == block.id &&
              r.lane == lane)
          .toList();
      occupant = r.isEmpty ? '?' : (nameById[r.first.playerId] ?? '?');
    }

    return DragTarget<Reservation>(
      onWillAcceptWithDetails: (_) => !taken,
      onAcceptWithDetails: (details) => setState(() {
        _staged[details.data.id] = (block, lane);
      }),
      builder: (context, candidates, _) {
        final highlighted = candidates.isNotEmpty && !taken;
        final isStaged = stagedEntry.isNotEmpty;
        return GestureDetector(
          // Tapping a staged entry un-stages it (back to the left column).
          onTap: isStaged
              ? () => setState(() => _staged.remove(stagedEntry.first.key))
              : null,
          child: Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              color: highlighted
                  ? scheme.secondaryContainer
                  : isStaged
                      ? scheme.secondaryContainer.withValues(alpha: 0.6)
                      : taken
                          ? scheme.surfaceContainerHighest
                              .withValues(alpha: 0.6)
                          : null,
              border: Border.all(
                color: taken && !isStaged
                    ? Colors.transparent
                    : scheme.outlineVariant,
              ),
            ),
            child: Text(
              occupant == null
                  ? 'Dráha $lane — volná'
                  : 'Dráha $lane — $occupant${isStaged ? ' (přesun)' : ''}',
              style: TextStyle(
                fontSize: 12,
                color: taken && !isStaged
                    ? scheme.onSurfaceVariant
                    : scheme.onSurface,
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _commit({required int unmovedCount}) async {
    if (unmovedCount > 0) {
      final proceed = await confirmDialog(
        context,
        title: 'Nepřesunuté rezervace',
        message: '$unmovedCount rezervací zůstane bez místa a budou zrušeny '
            'se zprávou „${widget.cancelNote}". Pokračovat?',
        confirmLabel: 'Pokračovat',
      );
      if (!proceed || !mounted) return;
    }
    setState(() => _committing = true);
    final ok = await tryAction(
      context,
      () async {
        for (final entry in _staged.entries) {
          await Api.moveReservation(
              entry.key, entry.value.$1.id, entry.value.$2);
        }
      },
      errorText: friendlyDbError,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _committing = false);
    }
  }
}
