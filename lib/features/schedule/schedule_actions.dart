import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/calendar_layout.dart' show hourMinuteAt;
import '../../domain/collation.dart';
import '../../domain/models.dart';
import '../../domain/schedule.dart';
import '../admin/widgets/block_dialog.dart';
import '../admin/widgets/blockage_dialog.dart';
import '../admin/widgets/match_dialog.dart';
import '../admin/widgets/notify_choice_dialog.dart';
import '../admin/widgets/rental_dialog.dart';
import '../admin/widgets/rental_occurrence_dialog.dart';
import 'schedule_callbacks.dart';

/// Every user action the schedule views can trigger, built once per
/// WeekScreen build from the current data. The callbacks keep exactly the
/// signatures the views already take; admin ones are null for non-admins
/// or while the placeholder grid shows (canEditBlocks false) — except the
/// rental edit, which never touches blocks and only needs an admin.
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
    required this.rentals,
    required this.me,
    required this.canEditBlocks,
    this.noAccountIds = const {},
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

  /// Every rental row as stored (series, one-time AND exception rows): a
  /// tapped calendar occurrence is a resolved copy, so the rental edit looks
  /// its raw series and same-date exception up here.
  final List<Rental> rentals;

  /// The signed-in profile; the views only fire [onBook] with one present.
  final Profile? me;

  /// Admin block gestures (long-press edit, tap-a-gap add) only exist for
  /// admins on the real DB block set — never on the placeholder grid.
  final bool canEditBlocks;

  /// Hand-made "hráči bez účtu" (0022): no e-mail, no app, so a cancel or
  /// a move never offers to message them.
  final Set<String> noAccountIds;

  final Map<Day, DayOverride> _overrideByDate;
  final Map<String, TimeBlock> _blockById;

  /// The two bundles the views take (see schedule_callbacks.dart).
  SlotCallbacks get slot => SlotCallbacks(
        onBook: onBook,
        onCancel: onCancel,
        onRental: onEditRental,
      );
  CalendarAdminHooks get admin => CalendarAdminHooks(
        onEditBlock: onEditBlock,
        onAddBlockInGap: onAddBlockInGap,
        onAddForDay: onAddForDay,
        onEditPrioritySlot: onEditPrioritySlot,
        onEditRental: onEditRental,
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

  /// Tap on a rented cell / click on a rental band = edit that day's
  /// rental. Admin-only, but NOT gated on [canEditBlocks]: exceptions never
  /// touch blocks, so the placeholder grid is no reason to hide it.
  void Function(Day, Rental)? get onEditRental =>
      (me?.isAdmin ?? false) ? _editRental : null;

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
    if (noAccountIds.contains(r.playerId)) {
      // A hráč bez účtu has no inbox: plain confirm, no note, no ping.
      final ok = await confirmDialog(
        context,
        title: 'Zrušit rezervaci?',
        message: '${dayFull(date)} · ${block.label} · Dráha ${r.lane}\n'
            'Hráč bez účtu se o zrušení nedozví.',
        confirmLabel: 'Zrušit rezervaci',
        cancelLabel: 'Zpět',
      );
      if (!ok || !context.mounted) return;
      await tryAction(
        context,
        () => Api.cancelReservation(r.id, note: '', notify: false),
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
        noAccountIds: noAccountIds,
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
        noAccountIds: noAccountIds,
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

  /// Tap on a rented cell / click on a rental band: a one-time rental opens
  /// its plain dialog, a weekly one the "jen tento den" dialog for that
  /// date (prefilled with the existing exception row when there is one).
  /// No past-date guard — rentals allow retro entries.
  void _editRental(Day date, Rental rental) {
    if (rental.weekday == null) {
      showDialog<void>(
        context: context,
        builder: (_) =>
            RentalDialog(existing: rental, laneCount: settings.laneCount),
      );
      return;
    }
    // Resolved copies carry the series' id; find the raw series row and
    // its exception for the date.
    Rental? series;
    Rental? child;
    for (final r in rentals) {
      if (r.id == rental.id) series = r;
      if (r.parentId == rental.id && r.date == date) child = r;
    }
    showDialog<void>(
      context: context,
      builder: (_) => RentalOccurrenceDialog(
        parent: series ?? rental,
        date: date,
        existing: child,
        laneCount: settings.laneCount,
      ),
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
    // admin picks whether (and how) to tell them. Hráči bez účtu have no
    // inbox: they move silently, and when nobody else moves there is no
    // choice to make.
    NotifyChoice? moveNotify;
    final moving = reservations
        .where((r) => r.date == date && r.blockId == block.id && r.isLive)
        .toList();
    final notifiable =
        moving.where((r) => !noAccountIds.contains(r.playerId)).length;
    if (moving.isNotEmpty && notifiable == 0) {
      moveNotify = const NotifyChoice(notify: false);
    } else if (notifiable > 0) {
      moveNotify = await showNotifyChoiceDialog(
        context,
        title: 'Upozornit na přesun?',
        summary: notifiable == 1
            ? 'Hráč dostane zprávu o novém čase '
                '${newStart.display()}–${newEnd.display()}.'
            : '$notifiable hráčů dostane zprávu o novém čase '
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
/// plus a player picker (defaults to the admin themself, labelled 'já';
/// a "hráč bez účtu" is suffixed '· bez účtu' so the admin knows the
/// booking will never reach an inbox). A roster has dozens of names, so
/// the picker is a search field — focused on open, so the phone keyboard
/// is up at once — matching the name or the board nick, over a short list
/// to tap. Pops the chosen player's id, or null on cancel.
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
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  static String _fold(String s) => foldDiacritics(s).toLowerCase();

  /// 'já' first, then every other player whose name or board nick contains
  /// the query (case- and diacritics-insensitive); empty query lists all.
  List<({String id, String title, String nick})> _candidates() {
    final q = _fold(_query.text.trim());
    bool hit(String s) => q.isEmpty || _fold(s).contains(q);
    return [
      if (hit('já') || hit(widget.me.displayName))
        (id: widget.me.id, title: 'já', nick: ''),
      for (final p in widget.players)
        if (p.id != widget.me.id && (hit(p.displayName) || hit(p.nick)))
          (
            id: p.id,
            title: p.hasAccount ? p.displayName : '${p.displayName} · bez účtu',
            nick: p.nick,
          ),
    ];
  }

  String get _selectedName => _playerId == widget.me.id
      ? 'já'
      : widget.players
              .where((p) => p.id == _playerId)
              .firstOrNull
              ?.displayName ??
          '';

  @override
  Widget build(BuildContext context) {
    final candidates = _candidates();
    return AlertDialog(
      title: const Text('Rezervovat termín?'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.message),
            const SizedBox(height: 12),
            TextField(
              controller: _query,
              // The keyboard is up the moment the dialog opens.
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Rezervovat pro',
                hintText: 'jméno nebo přezdívka',
                prefixIcon: const Icon(Icons.search),
                helperText: 'Vybráno: $_selectedName',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: candidates.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('Nikdo neodpovídá hledání.'),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final c in candidates)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(c.title),
                            subtitle:
                                c.nick.isEmpty ? null : Text('„${c.nick}“'),
                            selected: c.id == _playerId,
                            trailing: c.id == _playerId
                                ? const Icon(Icons.check)
                                : null,
                            onTap: () => setState(() => _playerId = c.id),
                          ),
                      ],
                    ),
            ),
          ],
        ),
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
