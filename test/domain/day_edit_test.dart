import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/day_edit.dart';
import 'package:rezervator/domain/models.dart';

void main() {
  const b1 = TimeBlock(
      id: 'b1',
      startsAt: HourMinute(16, 0),
      endsAt: HourMinute(17, 0),
      position: 0,
      active: true);
  const b2 = TimeBlock(
      id: 'b2',
      startsAt: HourMinute(17, 0),
      endsAt: HourMinute(18, 0),
      position: 1,
      active: true);
  // A deactivated TEMPLATE block — never a reuse candidate for specials.
  const b3 = TimeBlock(
      id: 'b3',
      startsAt: HourMinute(18, 0),
      endsAt: HourMinute(19, 0),
      position: 2,
      active: false);
  // Day-specials: inactive, position -1.
  const s1 = TimeBlock(
      id: 's1',
      startsAt: HourMinute(16, 30),
      endsAt: HourMinute(17, 30),
      position: -1,
      active: false);
  // Its times differ from b2's — editing it INTO b2's times is the dissolve.
  const s2 = TimeBlock(
      id: 's2',
      startsAt: HourMinute(17, 15),
      endsAt: HourMinute(18, 0),
      position: -1,
      active: false);
  const s3 = TimeBlock(
      id: 's3',
      startsAt: HourMinute(19, 0),
      endsAt: HourMinute(20, 0),
      position: -1,
      active: false);
  const all = [b1, b2, b3, s1, s2, s3];
  final date = Day(2026, 7, 16);
  final other = Day(2026, 7, 17);
  StrandableReservation row(Day d, String block, [int lane = 1]) =>
      StrandableReservation(date: d, lane: lane, blockId: block);

  group('helpers', () {
    test('strandedOnDate counts rows on the date outside the kept ids', () {
      final rows = [row(date, 'b1'), row(date, 'b2'), row(other, 'b2')];
      expect(strandedOnDate(rows, date, {'b1'}), 1);
      expect(strandedOnDate(rows, date, {'b1', 'b2'}), 0);
    });

    test('strandedByGrid counts lanes beyond the count and off-days', () {
      final rows = [row(date, 'b1', 4), row(date, 'b1', 2), row(other, 'b1')];
      // 2026-07-16 is Thursday (4), 07-17 Friday (5).
      expect(strandedByGrid(rows, laneCount: 3, trainingWeekdays: {4}), 2);
      expect(strandedByGrid(rows, laneCount: 4, trainingWeekdays: {4, 5}), 0);
    });

    test('strandedOnBlock, nextBlockPosition, templateBlockIds', () {
      expect(strandedOnBlock([row(date, 'b1'), row(other, 'b1')], 'b1'), 2);
      expect(nextBlockPosition(const []), 0);
      expect(nextBlockPosition(all), 3);
      expect(templateBlockIds(all), ['b1', 'b2']);
      expect(dayCancelNote('  '), scheduleChangeNote);
      expect(dayCancelNote('údržba'), 'údržba');
    });
  });

  group('planBlockEdit', () {
    test('global mode warns about overlapping ACTIVE blocks, not itself', () {
      final plan = planBlockEdit(
          start: const HourMinute(16, 30),
          end: const HourMinute(17, 30),
          existing: null,
          blocks: all,
          rows: const []) as DayEditGlobal;
      expect(plan.overlapping, [b1, b2]);
      final edit = planBlockEdit(
          start: const HourMinute(16, 0),
          end: const HourMinute(17, 0),
          existing: b1,
          blocks: all,
          rows: const []) as DayEditGlobal;
      expect(edit.overlapping, isEmpty);
    });

    test('unchanged times on a block the day already uses is a no-op', () {
      DayEditPlan plan(List<String> base) => planBlockEdit(
          start: b1.startsAt,
          end: b1.endsAt,
          existing: b1,
          blocks: all,
          day: DayEditContext(date: date, baseIds: base),
          rows: const []);
      expect(plan(['b1', 'b2']), isA<DayEditNoOp>());
      // Hidden by a match (not in the base) — saving it again is a real edit.
      expect(plan(['b2']), isA<DayEditDay>());
    });

    test('editing a special to exactly copy a template block dissolves', () {
      final rows = [row(date, 'b2'), row(date, 's2')];
      final plan = planBlockEdit(
          start: b2.startsAt,
          end: b2.endsAt,
          existing: s2,
          blocks: all,
          day: DayEditContext(date: date, baseIds: const ['b1', 's2']),
          rows: rows) as DayEditDay;
      expect(plan.dissolveTwin, b2);
      expect(plan.hidden, isEmpty);
      expect(plan.specialOverlaps, isEmpty);
      expect(plan.keptIds, {'b1', 's2', 'b2'});
      expect(plan.cancellations, 0);
      expect(plan.twinRows, 1);
      expect(plan.twinNeedsSweep, isTrue);
      expect(plan.movingRows, 1);
      expect(plan.dissolveIds, ['b1', 'b2']);
      expect(plan.unwindsOverride, isTrue);
    });

    test('dissolve dedups an already-present twin and never unwinds a '
        'non-training day', () {
      final plan = planBlockEdit(
          start: b2.startsAt,
          end: b2.endsAt,
          existing: s2,
          blocks: all,
          day: DayEditContext(
              date: date, baseIds: const ['b1', 's2', 'b2'], isTraining: false),
          rows: const []) as DayEditDay;
      expect(plan.dissolveIds, ['b1', 'b2']);
      expect(plan.unwindsOverride, isFalse);
    });

    test('new times hide the template blocks they touch; only rendered '
        'ones or ones with rows are noteworthy', () {
      DayEditDay plan(List<StrandableReservation> rows) => planBlockEdit(
          start: const HourMinute(16, 30),
          end: const HourMinute(17, 30),
          existing: null,
          blocks: all,
          day: DayEditContext(
              date: date, baseIds: const ['b1', 'b2'], renderedIds: {'b1'}),
          rows: rows) as DayEditDay;
      final quiet = plan(const []);
      expect(quiet.hidden, [b1, b2]);
      expect(quiet.noteworthy, [b1]);
      expect(quiet.hiddenRows, 0);
      expect(quiet.hiddenToCancel, isEmpty);

      final withRows = plan([row(date, 'b2'), row(other, 'b2')]);
      expect(withRows.noteworthy, [b1, b2]);
      expect(withRows.hiddenRows, 1);
      expect(withRows.hiddenToCancel, [b2]);
    });

    test('overlapping another special is reported separately', () {
      final plan = planBlockEdit(
          start: const HourMinute(16, 45),
          end: const HourMinute(17, 15),
          existing: null,
          blocks: all,
          day: DayEditContext(date: date, baseIds: const ['b1', 's1']),
          rows: const []) as DayEditDay;
      expect(plan.specialOverlaps, [s1]);
      expect(plan.hidden, [b1]);
    });

    test('kept ids = base + edited block + twin; cancellations use the '
        'RPC predicate; moving rows ride along', () {
      final rows = [
        row(date, 'b1'), // moves with the edit
        row(date, 'b2'), // kept
        row(date, 'b3'), // stranded on a non-kept block → cancelled
        row(other, 'b3'), // other date → untouched
      ];
      final plan = planBlockEdit(
          start: const HourMinute(16, 15),
          end: const HourMinute(17, 15),
          existing: b1,
          blocks: all,
          day: DayEditContext(
              date: date, baseIds: const ['b1', 'b2'], reason: 'údržba'),
          rows: rows) as DayEditDay;
      expect(plan.keptIds, {'b1', 'b2'});
      expect(plan.cancellations, 1);
      expect(plan.movingRows, 1);
      expect(plan.cancelNote, 'údržba');
      expect(plan.idsAfter('sbX'), ['sbX', 'b2']);
    });

    test('reuses an inactive sentinel special, never a deactivated '
        'template block', () {
      DayEditDay plan(HourMinute s, HourMinute e) => planBlockEdit(
          start: s,
          end: e,
          existing: null,
          blocks: all,
          day: DayEditContext(date: date, baseIds: const ['b1', 'b2']),
          rows: const []) as DayEditDay;
      expect(
          plan(const HourMinute(16, 30), const HourMinute(17, 30))
              .reusableSpecial,
          s1);
      expect(
          plan(const HourMinute(18, 0), const HourMinute(19, 0))
              .reusableSpecial,
          isNull);
      expect(
          plan(const HourMinute(18, 0), const HourMinute(19, 0))
              .idsAfter('sbX'),
          ['b1', 'b2', 'sbX']);
    });
  });

  group('planBlockRemoval', () {
    test('targets are overlapping blocks that still render, else every '
        'rendering block; the sweep keeps the removed block after a move',
        () {
      final plan = planBlockRemoval(
          existing: b1,
          day: DayEditContext(date: date, baseIds: const ['b1', 'b2', 's3']),
          blocks: all,
          rows: [row(date, 'b1'), row(date, 'b1', 2)]);
      expect(plan.idsAfter, ['b2', 's3']);
      expect(plan.signUps, 2);
      expect(plan.targets, [b2, s3]); // nothing overlaps 16–17 → fallback
      expect(plan.offersMove, isTrue);
      expect(plan.sweepKeptIds, {'b2', 's3', 'b1'});
      expect(plan.cancelNote, scheduleChangeNote);
    });

    test('a remaining special or a whole-alley match hides a target', () {
      final hiddenBySpecial = planBlockRemoval(
          existing: b1,
          day: DayEditContext(date: date, baseIds: const ['b1', 'b2', 's1']),
          blocks: all,
          rows: const []);
      // b2 (17–18) sits under s1 (16:30–17:30) → only s1 itself renders.
      expect(hiddenBySpecial.targets, [s1]);
      expect(hiddenBySpecial.offersMove, isFalse);
      expect(hiddenBySpecial.sweepKeptIds, {'b2', 's1'});

      final match = PrioritySlot(
          id: 'm',
          date: date,
          startsAt: const HourMinute(17, 0),
          endsAt: const HourMinute(18, 0),
          type: PrioritySlot.fallbackMatchType);
      final hiddenByMatch = planBlockRemoval(
          existing: b1,
          day: DayEditContext(
              date: date, baseIds: const ['b1', 'b2'], priority: [match]),
          blocks: all,
          rows: const []);
      expect(hiddenByMatch.targets, isEmpty);
    });
  });

  group('planRestoreTemplate', () {
    test('training day keeps the template, non-training day keeps nothing',
        () {
      final rows = [row(date, 'b1'), row(date, 's1'), row(other, 's1')];
      final training = planRestoreTemplate(
          date: date, isTraining: true, blocks: all, rows: rows);
      expect(training.templateIds, ['b1', 'b2']);
      expect(training.keptIds, {'b1', 'b2'});
      expect(training.cancellations, 1);
      final closed = planRestoreTemplate(
          date: date, isTraining: false, blocks: all, rows: rows);
      expect(closed.keptIds, isEmpty);
      expect(closed.cancellations, 2);
    });
  });
}
