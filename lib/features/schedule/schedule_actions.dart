import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/calendar_layout.dart' show hourMinuteAt;
import '../../domain/collation.dart';
import '../../domain/day_edit.dart'
    show blockStartedMessage, clockAtWrite, startPassedMessage;
import '../../domain/duties.dart' show MyDuty;
import '../../domain/labels.dart';
import '../../domain/models.dart';
import '../../domain/schedule.dart';
import '../admin/widgets/block_dialog.dart';
import '../admin/widgets/blockage_dialog.dart';
import '../admin/widgets/day_flows.dart';
import '../admin/widgets/match_dialog.dart';
import '../admin/widgets/notify_choice_dialog.dart';
import '../admin/widgets/rental_date_dialog.dart';
import '../admin/widgets/rental_dialog.dart';
import '../admin/widgets/rental_occurrence_dialog.dart';
import 'cancel_own_reservation.dart';
import 'schedule_callbacks.dart';
import 'widgets/group_booking_dialog.dart';

/// Every user action the schedule views can trigger, built once per
/// WeekScreen build from the current data. The callbacks keep exactly the
/// signatures the views already take; admin ones are null for non-admins
/// or while the placeholder grid shows (canEditBlocks false) — except the
/// rental edit, which never touches blocks and only needs an admin. The
/// player on canteen duty (0050) gets the day-block ones and the day menu
/// on the days of their own periods (see [canEditDay]), never the matches,
/// blockages or rentals.
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
    required this.now,
    required this.reservations,
    required this.rentals,
    required this.me,
    required this.canEditBlocks,
    this.noAccountIds = const {},
    this.groupMateIds = const {},
    this.duty = MyDuty.none,
    this.clock,
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

  /// The current time of [today] — the player on duty is held to blocks
  /// that have not started yet (0050).
  final HourMinute now;

  /// Reads the current time afresh (the screen's clock); null = [now]. A
  /// duty's day edit asks it again right before writing — a dialog left
  /// open may outlive the minute a block starts (0050).
  final HourMinute Function()? clock;

  /// This week's live reservations.
  final List<Reservation> reservations;

  /// Every rental row as stored (series, one-time AND exception rows): a
  /// tapped calendar occurrence is a resolved copy, so the rental edit looks
  /// its raw series and same-date exception up here.
  final List<Rental> rentals;

  /// The signed-in profile; the views only fire [onBook] with one present.
  final Profile? me;

  /// Block gestures (long-press edit, tap-a-gap add, the day menu) exist for
  /// admins and for a player with canteen duty periods (0050), on the real
  /// DB block set only — never on the placeholder grid. Which days is
  /// [canEditDay]'s question.
  final bool canEditBlocks;

  /// Hand-made "hráči bez účtu" (0022): no e-mail, no app, so a cancel or
  /// a move never offers to message them.
  final Set<String> noAccountIds;

  /// Group mates (0044) whose reservations the signed-in player may book
  /// and cancel as their own. Empty outside a group, for admins it does not
  /// matter (they may anything), the kiosk never sets it.
  final Set<String> groupMateIds;

  /// The signed-in player's canteen duty (0050), with two rights on two
  /// clocks. On duty TODAY ([onDuty]) they book and cancel for the others,
  /// on any day from today on. On the days of their OWN periods
  /// ([MyDuty.coversDay]), on duty today or not, they edit the blocks of
  /// single days — the week screen then also passes [canEditBlocks].
  /// Matches, blockages, rentals and the weekly template stay the admin's.
  final MyDuty duty;

  final Map<Day, DayOverride> _overrideByDate;
  final Map<String, TimeBlock> _blockById;

  bool get _isAdmin => me?.isAdmin ?? false;

  /// The signed-in player is on canteen duty today (0050).
  bool get onDuty => duty.onDuty;

  /// On duty today and not an admin — an admin's own rights already cover
  /// it. The booking side: booking and cancelling for others.
  bool get _asDuty => onDuty && !_isAdmin;

  /// Editing blocks on the strength of their own duty periods (0050): a
  /// player with duty periods, not an admin. Whether they are on duty today
  /// does not matter here.
  bool get _editsAsDuty => canEditBlocks && !_isAdmin;

  /// Whether the block gestures are offered on [date] (0050): the admin on
  /// any day, the player with duty periods only on a day of their own
  /// period and from today on — on duty today or not, exactly the server's
  /// `duty_edit_gate`. A day of someone else's, or one nobody serves, gets
  /// none of them.
  bool canEditDay(Day date) =>
      canEditBlocks &&
      (_isAdmin || (!date.isBefore(today) && duty.coversDay(date)));

  /// How a refusal reads: „Služba skončila…“ when a duty just ended.
  String _errorText(Object error) =>
      friendlyDbError(error, wasOnDuty: _asDuty);

  /// How a refusal of a block edit reads: „Služba skončila…“ when their
  /// duty is gone by now (0050).
  String _editErrorText(Object error) =>
      friendlyDbError(error, wasOnDuty: _editsAsDuty);

  /// How a refusal of a day edit reads: a duty's `too_late` is about the
  /// block, not a reservation.
  String _dayEditErrorText(Object error) =>
      dayEditError(error, wasOnDuty: _editsAsDuty);

  /// The current time, read afresh when the screen gave a [clock].
  HourMinute _now() => clock?.call() ?? now;

  /// The duty on [today] (0050): the clock, else null. The server refuses
  /// the duty's moves of blocks that have started by then and spares their
  /// reservations — the dialogs and flows hold to it, reading it again
  /// right before they write.
  HourMinute Function()? _dutyClockOn(Day date) =>
      _editsAsDuty && date == today ? _now : null;

  /// The two bundles the views take (see schedule_callbacks.dart).
  SlotCallbacks get slot => SlotCallbacks(
        onBook: onBook,
        onCancel: onCancel,
        onRental: onEditRental,
        onInfo: onInfo,
        groupMateIds: groupMateIds,
        onDuty: _asDuty,
      );
  CalendarAdminHooks get admin => CalendarAdminHooks(
        onEditBlock: onEditBlock,
        onAddBlockInGap: onAddBlockInGap,
        onAddForDay: onAddForDay,
        onEditPrioritySlot: onEditPrioritySlot,
        onEditRental: onEditRental,
        onMoveBlock: onMoveBlock,
        onMovePrioritySlot: onMovePrioritySlot,
        onCloseDay: onCloseDay,
        onRestoreDay: onRestoreDay,
        hasDayOverride: (date) => _overrideByDate[date] != null,
        canEditDay: canEditDay,
      );

  void Function(Day, TimeBlock, int lane) get onBook =>
      (Day date, TimeBlock block, int lane) =>
          _book(date, block, lane, me!);

  void Function(Day, TimeBlock, Reservation, {required bool ownFuture})
      get onCancel => _cancel;

  /// [slot_tile.dart] only fires this where [onCancel] would not — a
  /// signed-in player tapping someone else's reservation.
  void Function(Day, TimeBlock, Reservation)? get onInfo =>
      me == null ? null : (_, _, r) => _info(r);

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
      canEditBlocks && _isAdmin ? _editPrioritySlot : null;

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
      canEditBlocks && _isAdmin ? _movePrioritySlot : null;

  /// The portrait day menu (0050): close the day, or return it to the
  /// weekly rules — the same flows as the day-mode block dialog.
  void Function(Day)? get onCloseDay => canEditBlocks ? _closeDay : null;
  void Function(Day)? get onRestoreDay => canEditBlocks ? _restoreDay : null;

  Future<void> _book(
    Day date,
    TimeBlock block,
    int lane,
    Profile me,
  ) async {
    final message = '${dayFull(date)} · ${block.label} · Dráha $lane';
    String? playerId;
    if (_isAdmin || _asDuty) {
      playerId = await showDialog<String>(
        context: context,
        builder: (dialogContext) => _BookingDialog(
          message: message,
          me: me,
          players: ref.read(playersProvider).value ?? const [],
          settings: ref.read(settingsProvider).value,
          asDuty: _asDuty,
        ),
      );
    } else if (groupMateIds.isNotEmpty) {
      final mates = [
        for (final id in groupMateIds) (id: id, name: _displayNameOf(id)),
      ]..sort((a, b) => compareCzech(a.name, b.name));
      playerId = await showGroupBookingDialog(
        context,
        message: message,
        meId: me.id,
        mates: mates,
        settings: ref.read(settingsProvider).value,
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
      errorText: _errorText,
    );
  }

  /// Full name for [playerId] — the roster the admin booking dialog already
  /// reads. Only ever looked up right when a dialog opens (never carried on
  /// the board's own nameById, which is deliberately the shorter nick), so
  /// admin cancel dialogs and [_info] can name someone their board nick
  /// alone might not identify.
  String _displayNameOf(String playerId) {
    for (final p in ref.read(playersProvider).value ?? const <PlayerName>[]) {
      if (p.id == playerId) return p.displayName;
    }
    return '?';
  }

  /// A player taps a reservation that is not theirs and they cannot cancel:
  /// the board only had room for a nick, so a quiet snack with the full
  /// name is all this needs — no dialog, nothing to decide.
  void _info(Reservation r) => snack(context, _displayNameOf(r.playerId));

  Future<void> _cancel(
    Day date,
    TimeBlock block,
    Reservation r, {
    required bool ownFuture,
  }) async {
    if (ownFuture) {
      await confirmCancelOwnReservation(
        context,
        reservation: r,
        block: block,
        cancel: (id) => Api.cancelReservation(id),
      );
      return;
    }
    // A group mate's (0044): the tile only offers it before the start, as
    // for one's own; the mate hears about it from the server. Checked
    // locally (not just relying on slot_tile.dart's cancellable gate) so a
    // non-admin can never fall through into the admin's flows below — only
    // the player on duty (0050) goes on to them, for anyone else's.
    if (!_isAdmin && (!_asDuty || groupMateIds.contains(r.playerId))) {
      if (!groupMateIds.contains(r.playerId)) return;
      final ok = await confirmDialog(
        context,
        title: 'Zrušit rezervaci?',
        message: '${_displayNameOf(r.playerId)}\n'
            '${dayFull(date)} · ${block.label} · Dráha ${r.lane}\n'
            'Dostane o tom zprávu.',
        confirmLabel: 'Zrušit rezervaci',
        cancelLabel: 'Zpět',
      );
      if (!ok || !context.mounted) return;
      await tryAction(
        context,
        () => Api.cancelReservation(r.id),
        success: 'Rezervace zrušena.',
        errorText: _errorText,
      );
      return;
    }
    if (noAccountIds.contains(r.playerId)) {
      // A hráč bez účtu has no inbox: plain confirm, no note, no ping.
      final ok = await confirmDialog(
        context,
        title: 'Zrušit rezervaci?',
        message: '${_displayNameOf(r.playerId)}\n'
            '${dayFull(date)} · ${block.label} · Dráha ${r.lane}\n'
            'Hráč bez účtu se o zrušení nedozví.',
        confirmLabel: 'Zrušit rezervaci',
        cancelLabel: 'Zpět',
      );
      if (!ok || !context.mounted) return;
      await tryAction(
        context,
        () => Api.cancelReservation(r.id, note: '', notify: false),
        success: 'Rezervace zrušena.',
        errorText: _errorText,
      );
      return;
    }
    // Phase 3: cancelling someone else's reservation asks whether to ping
    // the player; the note doubles as the notification's reason (and stays
    // stored for the attendance audit even when silent).
    final choice = await showNotifyChoiceDialog(
      context,
      title: 'Zrušit rezervaci',
      summary: '${_displayNameOf(r.playerId)}\n'
          '${dayFull(date)} · ${block.label} · Dráha ${r.lane}',
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
      errorText: _errorText,
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

  // The duty's clock on [date], one minute ahead when [atWrite] (the check
  // right before a write, see clockAtWrite); null = no limit.
  HourMinute? _dutyNowOn(Day date, {required bool atWrite}) {
    final now = _dutyClockOn(date)?.call();
    return now == null || !atWrite ? now : clockAtWrite(now);
  }

  // The duty's today: a block already under way stays the admin's (the
  // server refuses to move it and keeps its trainings).
  bool _guardStarted(Day date, TimeBlock block, {bool atWrite = false}) {
    final dutyNow = _dutyNowOn(date, atWrite: atWrite);
    if (dutyNow == null || block.startsAt.compareTo(dutyNow) > 0) {
      return false;
    }
    snack(context, blockStartedMessage);
    return true;
  }

  // The duty's today: a new start that has passed is refused — checked
  // before the special is inserted, the server's refusal would come only
  // after it.
  // The snack prints the clock's real reading, not the write-time margin.
  bool _guardStartPassed(Day date, HourMinute start, {bool atWrite = false}) {
    final now = _dutyClockOn(date)?.call();
    if (now == null) return false;
    final dutyNow = atWrite ? clockAtWrite(now) : now;
    if (start.compareTo(dutyNow) > 0) return false;
    snack(context, startPassedMessage(now));
    return true;
  }

  void _editBlock(Day date, TimeBlock block) {
    if (_guardPast(date) || _guardStarted(date, block)) return;
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
        wasOnDuty: _editsAsDuty,
        dutyClock: _dutyClockOn(date),
      ),
    );
  }

  Future<void> _openAdd(Day date,
      {HourMinute? start, HourMinute? end}) async {
    if (_guardPast(date)) return;
    final closed = week.days[date.weekday - 1] is ClosedDay;
    // Adding a block into a CLOSED day reopens it — that's a bigger
    // decision than the dialog title suggests, so say it out loud.
    if (closed) {
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
        // The header ＋ (no gap picked) on an open day may close it too.
        offerCloseDay: !closed && start == null && end == null,
        wasOnDuty: _editsAsDuty,
        dutyClock: _dutyClockOn(date),
      ),
    );
  }

  Future<void> _closeDay(Day date) async {
    if (_guardPast(date)) return;
    await closeDayFlow(
      context,
      date: date,
      errorText: _editErrorText,
      blocks: dbBlocks,
      renderedIds: _dayRenderedIds(date),
      dutyClock: _dutyClockOn(date),
    );
  }

  Future<void> _restoreDay(Day date) async {
    if (_guardPast(date)) return;
    await restoreDayFlow(
      context,
      date: date,
      isTraining: settings.trainingWeekdays.contains(date.weekday),
      blocks: dbBlocks,
      renderedIds: _dayRenderedIds(date),
      errorText: _editErrorText,
      dutyClock: _dutyClockOn(date),
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

  /// Tap on a rented cell / click on a rental band: a lone one-time rental
  /// opens its plain dialog, a date of a nepravidelný pronájem (0041) the
  /// one-date dialog, and a weekly one the "jen tento den" dialog for that
  /// date (prefilled with the existing exception row when there is one).
  /// No past-date guard — rentals allow retro entries.
  ///
  /// A grouped date must NOT open the plain rental dialog: it offers Nájemce
  /// and Barva, but those belong to the group — `rental_group_guard` copies
  /// them back from `rental_groups` over whatever the PATCH sent, so the
  /// screen would report a saved edit the server threw away. Renaming lives
  /// on Pronájmy → Upravit (`Api.saveRentalGroup`). Same reason an exception
  /// row is edited by RentalOccurrenceDialog rather than this form (0021).
  void _editRental(Day date, Rental rental) {
    if (rental.weekday == null) {
      showDialog<void>(
        context: context,
        builder: (_) => rental.groupId != null
            ? RentalDateDialog(
                anchor: rental,
                existing: rental,
                laneCount: settings.laneCount,
              )
            : RentalDialog(existing: rental, laneCount: settings.laneCount),
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
    if (_guardPast(date) || _guardStarted(date, block)) return;
    if (_guardStartPassed(date, newStart)) return;
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
    // The clock is asked again right before any write (the choice took
    // time), with the one-minute margin.
    if (_guardStarted(date, block, atWrite: true) ||
        _guardStartPassed(date, newStart, atWrite: true)) {
      return;
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
      errorText: _dayEditErrorText,
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
      errorText: _errorText,
    );
  }
}

/// The admin's — and the canteen duty's (0050) — booking dialog: same
/// confirmation as the plain player flow, plus a player picker (defaults to
/// the one booking, labelled 'já';
/// a "hráč bez účtu" is suffixed '· bez účtu' so the admin knows the
/// booking will never reach an inbox). A roster has dozens of names, so
/// the picker is a search field — focused on open, so the phone keyboard
/// is up at once — matching the name or the board nick, over a short list
/// to tap. Pops the chosen player's id, or null on cancel.
class _BookingDialog extends ConsumerStatefulWidget {
  const _BookingDialog({
    required this.message,
    required this.me,
    required this.players,
    required this.settings,
    this.asDuty = false,
  });

  final String message;
  final Profile me;
  final List<PlayerName> players;

  /// For the cap: `create_reservation` lets an ADMIN book past
  /// `max_active_reservations` — the dialog warns instead of refusing.
  final ScheduleSettings? settings;

  /// Opened by the player on canteen duty (0050): the booked player's cap
  /// is a wall, not a warning — „Rezervovat“ goes grey for a player at it.
  final bool asDuty;

  @override
  ConsumerState<_BookingDialog> createState() => _BookingDialogState();
}

class _BookingDialogState extends ConsumerState<_BookingDialog> {
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

  /// The chosen player's name for a sentence about THEM; the admin's own
  /// name when they are the choice, which only the null branch of
  /// [reservationLimitAdminNote] ever needs to avoid.
  String get _selectedFullName => _playerId == widget.me.id
      ? widget.me.displayName
      : widget.players
              .where((p) => p.id == _playerId)
              .firstOrNull
              ?.displayName ??
          '';

  /// The cap note for whoever is chosen right now, or null while the
  /// count is still loading, failed, or leaves them under the cap. Failing
  /// silently is the honest fallback: the RPC decides either way, so a
  /// count the app could not fetch must not stand in the way.
  String? _limitWarning() {
    if (_chosenAtLimit() != true) return null;
    final who = _playerId == widget.me.id ? null : _selectedFullName;
    final max = widget.settings!.maxActiveReservations;
    return widget.asDuty
        ? reservationLimitDutyNote(who, max)
        : reservationLimitAdminNote(who, max);
  }

  /// Whether whoever is chosen right now is at the cap; null while the count
  /// is loading or failed — the RPC decides then.
  bool? _chosenAtLimit() {
    final settings = widget.settings;
    if (settings == null) return null;
    final count =
        ref.watch(activeReservationCountProvider(_playerId)).value;
    return count == null ? null : atReservationLimit(count, settings);
  }

  @override
  Widget build(BuildContext context) {
    final candidates = _candidates();
    // The cap warning takes three lines, and while the keyboard is up the
    // whole dialog has some 455px — three lines is two names fewer. So it
    // steps aside during the search and comes back the moment the keyboard
    // goes, which is when it is actually read: picking a name closes the
    // keyboard, and Rezervovat is the next tap.
    final warning =
        MediaQuery.viewInsetsOf(context).bottom > 0 ? null : _limitWarning();
    return AlertDialog(
      title: const Text('Rezervovat termín?'),
      // A fixed width: the dialog sizes its content by intrinsic width,
      // which a ListView cannot report, and the phone clamps 400 to the
      // screen anyway; a desktop browser stops stretching the dialog.
      content: SizedBox(
        width: 400,
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
            if (warning != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_outlined,
                        color: Theme.of(context).colorScheme.tertiary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        warning,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            // A box of its own, the same one from the first keystroke to
            // the last. Two things used to move it: it asked for the height
            // of its contents, so a fixed 220 under the message, the field
            // and the warning ran out of the dialog — the names were painted
            // across the page behind it, with Zrušit and Rezervovat sitting
            // on top of them — and then it shrank as typing narrowed eight
            // names to one, and the dialog jumped under the finger doing the
            // typing. So: 220 where there is room for 220, whatever is left
            // where there is not, and the same either way however many names
            // answer the search.
            Flexible(
              child: SizedBox(
                height: 220,
                child: candidates.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('Nikdo neodpovídá hledání.'),
                      )
                    : ListView(
                        // Reaching for the names means the typing is done:
                        // letting the keyboard go hands the dialog back some
                        // 330px, and the list grows into them.
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
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
                              onTap: () {
                                // Picked — the search is over. The keyboard
                                // goes, the dialog gets its height back, and
                                // the cap warning (if any) is there to read
                                // before Rezervovat.
                                FocusScope.of(context).unfocus();
                                setState(() => _playerId = c.id);
                              },
                            ),
                        ],
                      ),
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
          // The duty cannot book past a player's cap (0050); the admin can.
          onPressed: widget.asDuty && _chosenAtLimit() == true
              ? null
              : () => Navigator.pop(context, _playerId),
          child: const Text('Rezervovat'),
        ),
      ],
    );
  }
}
