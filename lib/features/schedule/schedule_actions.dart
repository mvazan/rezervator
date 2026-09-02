import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/calendar_layout.dart' show hourMinuteAt;
import '../../domain/models.dart';
import '../../domain/schedule.dart';
import '../admin/matches_screen.dart' show MatchDialog;
import '../admin/widgets/block_dialog.dart';
import '../admin/widgets/blockage_dialog.dart';
import '../admin/widgets/notify_choice_dialog.dart';
import 'schedule_callbacks.dart';

/// Every user action the schedule views can trigger, built once per
/// WeekScreen build from the current data. The callbacks keep exactly the
/// signatures the views already take; admin ones are null for non-admins
/// or while the placeholder grid shows (canEditBlocks false).
///
/// Calendar edits are DAY-SCOPED: they compose a day override around an
/// inactive "special" block instead of touching the weekly template (that
/// lives in Admin → Rozvrh).
class ScheduleActions {
  ScheduleActions({
    required this.context,
    required this.ref,
    required this.week,
    required this.dbBlocks,
    required this.overrides,
    required this.priority,
    required this.slotTypes,
    required this.settings,
    required this.today,
    required this.reservations,
    required this.me,
    required this.canEditBlocks,
  })  : _overrideByDate = {for (final o in overrides) o.date: o},
        _blockById = {for (final b in dbBlocks) b.id: b};

  /// The screen's context: dialogs and snacks open on it, and every flow
  /// re-checks `context.mounted` after an await.
  final BuildContext context;

  /// Reads the player roster for the admin booking dialog.
  final WidgetRef ref;

  final WeekSchedule week;

  /// The real DB block set — empty while the placeholder grid shows.
  final List<TimeBlock> dbBlocks;

  final List<DayOverride> overrides;
  final List<PrioritySlot> priority;
  final List<PrioritySlotType> slotTypes;
  final ScheduleSettings settings;
  final Day today;

  /// This week's live reservations.
  final List<Reservation> reservations;

  /// The signed-in profile; the views only fire [onBook] with one present.
  final Profile? me;

  /// Admin block gestures (long-press edit, tap-a-gap add) only exist for
  /// admins on the real DB block set — never on the placeholder grid.
  final bool canEditBlocks;

  final Map<Day, DayOverride> _overrideByDate;
  final Map<String, TimeBlock> _blockById;

  /// The two bundles the views take (see schedule_callbacks.dart).
  SlotCallbacks get slot => SlotCallbacks(onBook: onBook, onCancel: onCancel);
  CalendarAdminHooks get admin => CalendarAdminHooks(
        onEditBlock: onEditBlock,
        onAddBlockInGap: onAddBlockInGap,
        onAddForDay: onAddForDay,
        onEditPrioritySlot: onEditPrioritySlot,
        onMoveBlock: onMoveBlock,
        onMovePrioritySlot: onMovePrioritySlot,
      );

  void Function(Day, TimeBlock, int lane) get onBook =>
      (Day date, TimeBlock block, int lane) =>
          _book(date, block, lane, me!, me!.isAdmin);

  void Function(Day, TimeBlock, Reservation, {required bool ownFuture})
      get onCancel => _cancel;

  void Function(Day, TimeBlock)? get onEditBlock =>
      canEditBlocks ? _editBlock : null;

  void Function(Day, HourMinute, HourMinute)? get onAddBlockInGap =>
      canEditBlocks
          ? (Day date, HourMinute start, HourMinute end) =>
              _openAdd(date, start: start, end: end)
          : null;

  /// Header ＋: add a slot to a day whose column has no empty space left
  /// to tap — same dialog, times picked in the dialog.
  void Function(Day)? get onAddForDay =>
      canEditBlocks ? (Day date) => _openAdd(date) : null;

  /// Click on a blocking band = edit. An úklid child opens its parent
  /// match (it is auto-managed); matches open the match dialog, other
  /// blockages the blockage dialog.
  void Function(Day, PrioritySlot)? get onEditPrioritySlot =>
      canEditBlocks ? _editPrioritySlot : null;

  /// HOLD-drag moves. A training block moves day-scoped (its sign-ups
  /// travel along); a blocking slot just gets new times (the server drags
  /// a match's úklid child with it).
  void Function(Day, TimeBlock, HourMinute)? get onMoveBlock =>
      canEditBlocks ? _moveBlock : null;

  void Function(Day, PrioritySlot, HourMinute)? get onMovePrioritySlot =>
      canEditBlocks ? _movePrioritySlot : null;

  Future<void> _book(
    Day date,
    TimeBlock block,
    int lane,
    Profile me,
    bool isAdmin,
  ) async {
    final message = '${dayFull(date)} · ${block.label} · Dráha $lane';
    String? playerId;
    if (isAdmin) {
      playerId = await showDialog<String>(
        context: context,
        builder: (dialogContext) => _BookingDialog(
          message: message,
          me: me,
          players: ref.read(playersProvider).value ?? const [],
        ),
      );
    } else {
      final confirmed = await confirmDialog(
        context,
        title: 'Rezervovat termín?',
        message: message,
        confirmLabel: 'Rezervovat',
      );
      playerId = confirmed ? me.id : null;
    }
    if (playerId == null || !context.mounted) return;
    await tryAction(
      context,
      () => Api.createReservation(
        playerId: playerId!,
        date: date,
        blockId: block.id,
        lane: lane,
      ),
      success: 'Zarezervováno.',
      errorText: friendlyDbError,
    );
  }

  Future<void> _cancel(
    Day date,
    TimeBlock block,
    Reservation r, {
    required bool ownFuture,
  }) async {
    if (ownFuture) {
      final ok = await confirmDialog(
        context,
        title: 'Zrušit rezervaci?',
        message: '${dayFull(date)} · ${block.label} · Dráha ${r.lane}',
        confirmLabel: 'Zrušit rezervaci',
        cancelLabel: 'Zpět',
      );
      if (!ok || !context.mounted) return;
      await tryAction(
        context,
        () => Api.cancelReservation(r.id),
        success: 'Rezervace zrušena.',
        errorText: friendlyDbError,
      );
      return;
    }
    // Phase 3: cancelling someone else's reservation asks whether to ping
    // the player; the note doubles as the notification's reason (and stays
    // stored for the attendance audit even when silent).
    final choice = await showNotifyChoiceDialog(
      context,
      title: 'Zrušit rezervaci',
      summary: '${dayFull(date)} · ${block.label} · Dráha ${r.lane}',
      messageLabel: 'Poznámka / důvod (nepovinné)',
      sendLabel: 'Zrušit a poslat zprávu',
      silentLabel: 'Zrušit bez zprávy',
    );
    if (choice == null || !context.mounted) return;
    await tryAction(
      context,
      () => Api.cancelReservation(r.id,
          note: choice.message ?? '', notify: choice.notify),
      success: 'Rezervace zrušena.',
      errorText: friendlyDbError,
    );
  }

  // The day's PRE-cancellation block ids (existing override selection or
  // the active weekly template) — what the new override is composed from.
  // A day that renders CLOSED (override or non-training weekday) starts
  // from an empty base: adding a block there opens the day with exactly
  // that block, never with the whole weekly template in tow.
  List<String> _dayBaseIds(Day date) {
    final o = _overrideByDate[date];
    if (o != null && !o.closed && o.blockIds != null) {
      return [
        for (final id in o.blockIds!)
          if (_blockById.containsKey(id)) id,
      ];
    }
    if (week.days[date.weekday - 1] is ClosedDay) return const [];
    return [
      for (final b in dbBlocks)
        if (b.active) b.id,
    ];
  }

  // What the day actually renders — a match-cancelled block hides
  // silently (nothing visible changes), only visible/reserved ones warn.
  Set<String> _dayRenderedIds(Day date) {
    final day = week.days[date.weekday - 1];
    return day is OpenDay && day.date == date
        ? {for (final b in day.blocks) b.id}
        : const {};
  }

  // Past days are history: set_day_override would cancel their (already
  // played) reservations and corrupt attendance — the gestures refuse.
  bool _guardPast(Day date) {
    if (!date.isBefore(today)) return false;
    snack(context, 'Minulé dny nelze upravovat.');
    return true;
  }

  void _editBlock(Day date, TimeBlock block) {
    if (_guardPast(date)) return;
    showDialog<void>(
      context: context,
      builder: (_) => BlockDialog(
        existing: block,
        blocks: dbBlocks,
        dayContext: date,
        dayBaseIds: _dayBaseIds(date),
        dayRenderedIds: _dayRenderedIds(date),
        dayHasOverride: _overrideByDate[date] != null,
        dayIsTraining: settings.trainingWeekdays.contains(date.weekday),
        dayPriority: week.days[date.weekday - 1].priority,
        dayReason: _overrideByDate[date]?.reason ?? '',
      ),
    );
  }

  Future<void> _openAdd(Day date,
      {HourMinute? start, HourMinute? end}) async {
    if (_guardPast(date)) return;
    // Adding a block into a CLOSED day reopens it — that's a bigger
    // decision than the dialog title suggests, so say it out loud.
    if (week.days[date.weekday - 1] is ClosedDay) {
      final reason = _overrideByDate[date]?.reason ?? '';
      final proceed = await confirmDialog(
        context,
        title: 'Den je zavřený',
        message: reason.isEmpty
            ? '${dayFull(date)} je zavřeno. Přidáním bloku den '
                'otevřeš. Pokračovat?'
            : '${dayFull(date)} je zavřeno („$reason"). Přidáním '
                'bloku den otevřeš. Pokračovat?',
        confirmLabel: 'Otevřít den',
      );
      if (!proceed || !context.mounted) return;
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => BlockDialog(
        existing: null,
        blocks: dbBlocks,
        initialStart: start,
        initialEnd: end,
        dayContext: date,
        dayBaseIds: _dayBaseIds(date),
        dayRenderedIds: _dayRenderedIds(date),
        dayHasOverride: _overrideByDate[date] != null,
        dayIsTraining: settings.trainingWeekdays.contains(date.weekday),
        dayPriority: week.days[date.weekday - 1].priority,
        dayReason: _overrideByDate[date]?.reason ?? '',
      ),
    );
  }

  void _editPrioritySlot(Day date, PrioritySlot slot) {
    var target = slot;
    if (slot.parentId != null) {
      final parent =
          priority.where((m) => m.id == slot.parentId).firstOrNull;
      if (parent == null) return;
      target = parent;
    }
    showDialog<void>(
      context: context,
      builder: (_) => target.type.isMatch
          ? MatchDialog(existing: target, types: slotTypes)
          : BlockageDialog(existing: target, types: slotTypes),
    );
  }

  Future<void> _moveBlock(
      Day date, TimeBlock block, HourMinute newStart) async {
    if (_guardPast(date)) return;
    final endMinutes = newStart.minutesFromMidnight + block.durationMinutes;
    if (endMinutes > 24 * 60 - 1) {
      snack(context, 'Blok se nevejde do dne.');
      return;
    }
    final newEnd = hourMinuteAt(endMinutes);
    // Phase 3: the block's sign-ups travel to the new time — the
    // admin picks whether (and how) to tell them.
    NotifyChoice? moveNotify;
    final movingRows = reservations
        .where((r) => r.date == date && r.blockId == block.id && r.isLive)
        .length;
    if (movingRows > 0) {
      moveNotify = await showNotifyChoiceDialog(
        context,
        title: 'Upozornit na přesun?',
        summary: movingRows == 1
            ? 'Hráč dostane zprávu o novém čase '
                '${newStart.display()}–${newEnd.display()}.'
            : '$movingRows hráčů dostane zprávu o novém čase '
                '${newStart.display()}–${newEnd.display()}.',
      );
      if (moveNotify == null || !context.mounted) return;
    }
    await tryAction(
      context,
      () async {
        // Same day-scoped composition BlockDialog uses: sentinel
        // special (reuse or insert), sign-ups travel, override swap.
        TimeBlock? special;
        for (final b in dbBlocks) {
          if (!b.active &&
              b.position < 0 &&
              b.startsAt == newStart &&
              b.endsAt == newEnd) {
            special = b;
            break;
          }
        }
        final specialId =
            special?.id ?? await Api.addSpecialBlock(newStart, newEnd);
        await Api.moveDayReservations(date, block.id, specialId,
            notify: moveNotify?.notify ?? true,
            message: moveNotify?.message);
        final base = _dayBaseIds(date);
        final ids = base.contains(block.id)
            ? [for (final id in base) id == block.id ? specialId : id]
            : [...base, specialId];
        await Api.setDayOverride(
          date: date,
          closed: false,
          reason: _overrideByDate[date]?.reason ?? '',
          blockIds: ids,
        );
      },
      success: 'Přesunuto (jen tento den).',
      errorText: friendlyDbError,
    );
  }

  Future<void> _movePrioritySlot(
      Day date, PrioritySlot slot, HourMinute newStart) async {
    if (_guardPast(date)) return;
    final dur =
        slot.endsAt.minutesFromMidnight - slot.startsAt.minutesFromMidnight;
    final endMinutes = newStart.minutesFromMidnight + dur;
    if (endMinutes > 24 * 60 - 1) {
      snack(context, 'Slot se nevejde do dne.');
      return;
    }
    await tryAction(
      context,
      () => Api.savePrioritySlot(
        id: slot.id,
        date: date,
        startsAt: newStart,
        endsAt: hourMinuteAt(endMinutes),
        typeId: slot.type.id,
        homeTeam: slot.homeTeam,
        awayTeam: slot.awayTeam,
        prepMinutes: slot.prepMinutes,
        description: slot.description,
      ),
      success: 'Přesunuto.',
      errorText: friendlyDbError,
    );
  }
}

/// Admin-only booking dialog: same confirmation as the plain player flow,
/// plus a player picker (defaults to the admin themself, labelled 'já').
/// Pops the chosen player's id, or null on cancel.
class _BookingDialog extends StatefulWidget {
  const _BookingDialog({
    required this.message,
    required this.me,
    required this.players,
  });

  final String message;
  final Profile me;
  final List<PlayerName> players;

  @override
  State<_BookingDialog> createState() => _BookingDialogState();
}

class _BookingDialogState extends State<_BookingDialog> {
  late String _playerId = widget.me.id;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rezervovat termín?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _playerId,
            decoration: const InputDecoration(labelText: 'Rezervovat pro'),
            items: [
              DropdownMenuItem(value: widget.me.id, child: const Text('já')),
              for (final p in widget.players)
                if (p.id != widget.me.id)
                  DropdownMenuItem(value: p.id, child: Text(p.displayName)),
            ],
            onChanged: (v) => setState(() => _playerId = v!),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _playerId),
          child: const Text('Rezervovat'),
        ),
      ],
    );
  }
}
