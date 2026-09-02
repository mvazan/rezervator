/// Pure planning for the calendar's block edits (BlockDialog) and the
/// stranded-reservation warnings the admin screens show before a schedule
/// change. The widgets fetch the reservation picture, ask one of the
/// `plan*` functions what the edit means, sequence the confirm dialogs and
/// finally issue the RPC calls the plan prescribes — no rule lives in a
/// widget any more.
library;

import 'models.dart';
import 'schedule.dart' show timesOverlap;

/// The note every day-scoped write falls back to (set_day_override and the
/// 0018 cascade use the same wording).
const scheduleChangeNote = 'změna rozvrhu';

/// The note a day-scoped write will actually carry: the override's reason,
/// or the standard wording when it is blank.
String dayCancelNote(String reason) =>
    reason.trim().isEmpty ? scheduleChangeNote : reason;

/// Future live rows on [date] whose block is outside [keptIds] — exactly the
/// rows set_day_override cancels for that date.
int strandedOnDate(
        Iterable<StrandableReservation> rows, Day date, Set<String> keptIds) =>
    rows.where((r) => r.date == date && !keptIds.contains(r.blockId)).length;

/// Rows that would fall outside the grid after a settings change (fewer
/// lanes, a weekday dropped). A conservative upper bound: a day override may
/// keep a non-training day open, but the admin still gets warned.
int strandedByGrid(
  Iterable<StrandableReservation> rows, {
  required int laneCount,
  required Set<int> trainingWeekdays,
}) =>
    rows
        .where((r) =>
            r.lane > laneCount || !trainingWeekdays.contains(r.date.weekday))
        .length;

/// Rows on one block, any date — what deactivating it would cancel.
int strandedOnBlock(Iterable<StrandableReservation> rows, String blockId) =>
    rows.where((r) => r.blockId == blockId).length;

/// Position for a new weekly block: max(position) + 1, 0 for an empty list.
int nextBlockPosition(Iterable<TimeBlock> blocks) {
  var max = -1;
  for (final b in blocks) {
    if (b.position > max) max = b.position;
  }
  return max + 1;
}

/// Ids of the active weekly-template blocks (day-specials excluded).
List<String> templateBlockIds(Iterable<TimeBlock> blocks) => [
      for (final b in blocks)
        if (b.active && b.position >= 0) b.id,
    ];

/// What the dialog knows about the day it edits.
class DayEditContext {
  const DayEditContext({
    required this.date,
    required this.baseIds,
    this.renderedIds,
    this.isTraining = true,
    this.reason = '',
    this.priority = const [],
  });

  final Day date;

  /// The day's PRE-cancellation block ids (existing override selection, or
  /// the active weekly template) — the base the new override is composed
  /// from, so a block hidden by a priority slot isn't permanently lost.
  final List<String> baseIds;

  /// Ids of the blocks the day currently RENDERS. Hiding a block nobody can
  /// see needs no warning — unless it still holds live reservations. Null =
  /// warn for everything (conservative default).
  final Set<String>? renderedIds;

  /// Whether the WEEKDAY rule opens this day. Returning a non-training day
  /// to the template means CLOSING it again.
  final bool isTraining;

  /// The day's existing override reason, preserved on save.
  final String reason;

  /// The day's priority slots — a removal's move targets must still render
  /// after the removal (not sit under a whole-alley match).
  final List<PrioritySlot> priority;

  String get cancelNote => dayCancelNote(reason);
}

sealed class DayEditPlan {
  const DayEditPlan();
}

/// Unchanged times on a block the day already uses: nothing to write.
class DayEditNoOp extends DayEditPlan {
  const DayEditNoOp();
}

/// Weekly-template edit: [overlapping] active blocks would stack on every
/// training day and deserve a warning.
class DayEditGlobal extends DayEditPlan {
  const DayEditGlobal({required this.overlapping});

  final List<TimeBlock> overlapping;
}

/// Day-scoped edit, fully resolved. The widget confirms, in this order:
/// [specialOverlaps] → [noteworthy] (with [hiddenRows]) → [twinNeedsSweep]
/// → [cancellations] → the notify choice for [movingRows]; then writes:
/// dissolve ([dissolveIds] / [unwindsOverride]) or find-or-create the
/// special ([reusableSpecial], [idsAfter]).
class DayEditDay extends DayEditPlan {
  const DayEditDay({
    required this.date,
    required this.start,
    required this.end,
    required this.existing,
    required this.baseIds,
    required this.templateIds,
    required this.isTraining,
    required this.cancelNote,
    required this.dissolveTwin,
    required this.specialOverlaps,
    required this.hidden,
    required this.noteworthy,
    required this.hiddenRows,
    required this.hiddenToCancel,
    required this.twinRows,
    required this.keptIds,
    required this.cancellations,
    required this.movingRows,
    required this.reusableSpecial,
  });

  final Day date;
  final HourMinute start;
  final HourMinute end;
  final TimeBlock? existing;
  final List<String> baseIds;
  final List<String> templateIds;
  final bool isTraining;
  final String cancelNote;

  /// Editing a day-special so it EXACTLY copies an active template block
  /// hands the day back to that block.
  final TimeBlock? dissolveTwin;

  /// Other day-specials the new times overlap (specials don't hide each
  /// other — a real visual/booking overlap).
  final List<TimeBlock> specialOverlaps;

  /// Template blocks the new times touch — hidden for this day like a
  /// priority slot hides them (empty when dissolving).
  final List<TimeBlock> hidden;

  /// The subset of [hidden] worth a dialog: visible today, or still holding
  /// live rows.
  final List<TimeBlock> noteworthy;

  /// Live rows on the [noteworthy] blocks that the hide will cancel.
  final int hiddenRows;

  /// Hidden blocks whose live rows must cancel BEFORE the override write.
  final List<TimeBlock> hiddenToCancel;

  /// Live rows still sitting on the dissolve twin (legacy forks) — they
  /// must be swept or the 1:1 lane move collides.
  final int twinRows;

  /// Ids the RPC keeps: base + the edited block (its rows MOVE) + the twin.
  final Set<String> keptIds;

  /// Rows on the date outside [keptIds] — the RPC's exact cancel count.
  final int cancellations;

  /// Rows on the edited block that travel with it to the new times.
  final int movingRows;

  /// An existing inactive sentinel special with the picked times; null =
  /// insert a new one. Deactivated TEMPLATE blocks are never reused.
  final TimeBlock? reusableSpecial;

  bool get twinNeedsSweep => dissolveTwin != null && twinRows > 0;

  /// Override ids once the special [specialId] exists: appended for a new
  /// block, substituted for an edited one.
  List<String> idsAfter(String specialId) => existing == null
      ? [...baseIds, specialId]
      : [for (final id in baseIds) id == existing!.id ? specialId : id];

  /// Override ids when dissolving: the twin replaces the edited special,
  /// duplicates collapse.
  List<String> get dissolveIds {
    final twin = dissolveTwin!;
    final seen = <String>{};
    return [
      for (final id in baseIds)
        if (seen.add(id == existing!.id ? twin.id : id))
          id == existing!.id ? twin.id : id,
    ];
  }

  /// A dissolve on a training day that lands exactly on the weekly template
  /// unwinds the override row entirely (a non-training day would close
  /// again and strand the just-moved reservations).
  bool get unwindsOverride {
    if (dissolveTwin == null || !isTraining) return false;
    final ids = dissolveIds.toSet();
    final template = templateIds.toSet();
    return ids.length == template.length && ids.containsAll(template);
  }
}

TimeBlock? _firstBlock(
        Iterable<TimeBlock> blocks, bool Function(TimeBlock) test) {
  for (final b in blocks) {
    if (test(b)) return b;
  }
  return null;
}

/// Resolves a save of [start]–[end] for [existing] (null = new block).
/// [day] null = weekly-template (global) mode.
DayEditPlan planBlockEdit({
  required HourMinute start,
  required HourMinute end,
  required TimeBlock? existing,
  required List<TimeBlock> blocks,
  DayEditContext? day,
  required List<StrandableReservation> rows,
}) {
  if (day == null) {
    return DayEditGlobal(overlapping: [
      for (final b in blocks)
        if (b.active &&
            b.id != existing?.id &&
            timesOverlap(start, end, b.startsAt, b.endsAt))
          b,
    ]);
  }
  // Unchanged times on a block the day already uses must not fork the day
  // into an override (and cancel its reservations for a pixel-identical
  // schedule).
  if (existing != null &&
      start == existing.startsAt &&
      end == existing.endsAt &&
      day.baseIds.contains(existing.id)) {
    return const DayEditNoOp();
  }

  final twin = existing != null && existing.position < 0
      ? _firstBlock(
          blocks,
          (b) =>
              b.active &&
              b.position >= 0 &&
              b.startsAt == start &&
              b.endsAt == end)
      : null;

  final blockById = {for (final b in blocks) b.id: b};
  final baseBlocks = [
    for (final id in day.baseIds)
      if (id != existing?.id && blockById[id] != null) blockById[id]!,
  ];
  final specialOverlaps = [
    if (twin == null)
      for (final b in baseBlocks)
        if (b.position < 0 && timesOverlap(start, end, b.startsAt, b.endsAt))
          b,
  ];
  final hidden = [
    if (twin == null)
      for (final b in baseBlocks)
        if (b.position >= 0 && timesOverlap(start, end, b.startsAt, b.endsAt))
          b,
  ];
  bool hasRows(TimeBlock b) =>
      rows.any((r) => r.date == day.date && r.blockId == b.id);
  final noteworthy = [
    for (final b in hidden)
      if (day.renderedIds == null ||
          day.renderedIds!.contains(b.id) ||
          hasRows(b))
        b,
  ];
  final noteworthyIds = {for (final b in noteworthy) b.id};
  final hiddenRows = rows
      .where((r) => r.date == day.date && noteworthyIds.contains(r.blockId))
      .length;
  final keptIds = {
    ...day.baseIds,
    if (existing != null) existing.id,
    if (twin != null) twin.id,
  };
  return DayEditDay(
    date: day.date,
    start: start,
    end: end,
    existing: existing,
    baseIds: day.baseIds,
    templateIds: templateBlockIds(blocks),
    isTraining: day.isTraining,
    cancelNote: day.cancelNote,
    dissolveTwin: twin,
    specialOverlaps: specialOverlaps,
    hidden: hidden,
    noteworthy: noteworthy,
    hiddenRows: hiddenRows,
    hiddenToCancel: [
      for (final b in hidden)
        if (hasRows(b)) b,
    ],
    twinRows: twin == null
        ? 0
        : rows.where((r) => r.date == day.date && r.blockId == twin.id).length,
    keptIds: keptIds,
    cancellations: strandedOnDate(rows, day.date, keptIds),
    movingRows: existing == null
        ? 0
        : rows
            .where((r) => r.date == day.date && r.blockId == existing.id)
            .length,
    reusableSpecial: _firstBlock(
        blocks,
        (b) =>
            !b.active &&
            b.position < 0 &&
            b.startsAt == start &&
            b.endsAt == end),
  );
}

/// Removing [existing] from one day: the override loses its id; its
/// sign-ups may be re-seated onto [targets] (blocks that still RENDER after
/// the removal) before anything left unmoved is cancelled.
class DayRemovalPlan {
  const DayRemovalPlan({
    required this.existing,
    required this.idsAfter,
    required this.signUps,
    required this.targets,
    required this.cancelNote,
  });

  final TimeBlock existing;
  final List<String> idsAfter;
  final int signUps;
  final List<TimeBlock> targets;
  final String cancelNote;

  /// The move dialog is only worth showing with sign-ups AND somewhere to
  /// put them.
  bool get offersMove => signUps > 0 && targets.isNotEmpty;

  /// Ids the final sweep confirm treats as kept: after a successful move
  /// the removed block's rows were handled by the dialog, so only stranded
  /// rows on OTHER non-kept blocks remain to confirm.
  Set<String> get sweepKeptIds =>
      offersMove ? {...idsAfter, existing.id} : idsAfter.toSet();
}

DayRemovalPlan planBlockRemoval({
  required TimeBlock existing,
  required DayEditContext day,
  required List<TimeBlock> blocks,
  required List<StrandableReservation> rows,
}) {
  final ids = [
    for (final id in day.baseIds)
      if (id != existing.id) id,
  ];
  final blockById = {for (final b in blocks) b.id: b};
  // A move target must actually RENDER once the removal lands: not hidden
  // by a special that stays in the override, nor cancelled by a whole-alley
  // priority slot — else the moved reservations vanish.
  final remainingSpecials = [
    for (final id in ids)
      if (blockById[id] != null && blockById[id]!.position < 0) blockById[id]!,
  ];
  // (A special never hides itself — the old inline check compared a
  // special with its own interval and so never offered specials as
  // targets.)
  bool willRender(TimeBlock b) =>
      !remainingSpecials.any((s) =>
          s.id != b.id &&
          timesOverlap(b.startsAt, b.endsAt, s.startsAt, s.endsAt)) &&
      !day.priority.any((m) =>
          m.type.lanes == null &&
          !m.type.unresolved &&
          timesOverlap(b.startsAt, b.endsAt, m.startsAt, m.endsAt));
  var targets = [
    for (final id in ids)
      if (blockById[id] != null &&
          timesOverlap(existing.startsAt, existing.endsAt,
              blockById[id]!.startsAt, blockById[id]!.endsAt) &&
          willRender(blockById[id]!))
        blockById[id]!,
  ];
  if (targets.isEmpty) {
    // Nothing overlaps — offer every block that still renders that day
    // rather than forcing a cancellation.
    targets = [
      for (final id in ids)
        if (blockById[id] != null && willRender(blockById[id]!))
          blockById[id]!,
    ];
  }
  return DayRemovalPlan(
    existing: existing,
    idsAfter: ids,
    signUps: rows
        .where((r) => r.date == day.date && r.blockId == existing.id)
        .length,
    targets: targets,
    cancelNote: day.cancelNote,
  );
}

/// Dropping a day's fork: a training day goes back to the template blocks,
/// a NON-training day closes again — [keptIds] is what survives, and
/// [cancellations] counts the rows on the date that don't.
class RestorePlan {
  const RestorePlan({
    required this.templateIds,
    required this.keptIds,
    required this.cancellations,
  });

  final List<String> templateIds;
  final Set<String> keptIds;
  final int cancellations;
}

RestorePlan planRestoreTemplate({
  required Day date,
  required bool isTraining,
  required List<TimeBlock> blocks,
  required List<StrandableReservation> rows,
}) {
  final templateIds = templateBlockIds(blocks);
  final kept = isTraining ? templateIds.toSet() : <String>{};
  return RestorePlan(
    templateIds: templateIds,
    keptIds: kept,
    cancellations: strandedOnDate(rows, date, kept),
  );
}
