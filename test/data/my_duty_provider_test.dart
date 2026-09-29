import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/duties.dart';
import 'package:rezervator/domain/models.dart';

/// myDutyProvider (0050): the signed-in player's duty from the two duty
/// streams and the app clock — it must flip at midnight on its own, with no
/// new rows arriving, because the server judges every call by Prague today.
void main() {
  const me = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );
  final periods = [
    DutyPeriod(
      id: 'next',
      startsOn: Day(2026, 10, 12),
      endsOn: Day(2026, 10, 18),
    ),
    DutyPeriod(
      id: 'now',
      startsOn: Day(2026, 10, 5),
      endsOn: Day(2026, 10, 11),
    ),
  ];
  const assignments = [
    DutyAssignment(periodId: 'now', userId: 'me'),
    DutyAssignment(periodId: 'now', userId: 'jana'),
    DutyAssignment(periodId: 'next', userId: 'petr'),
  ];

  Future<(ProviderContainer, StreamController<DateTime>)> container({
    Profile? profile = me,
    required DateTime start,
    List<DutyAssignment> roster = assignments,
  }) async {
    final clock = StreamController<DateTime>();
    addTearDown(clock.close);
    final c = ProviderContainer(
      overrides: [
        nowProvider.overrideWith((ref) => clock.stream),
        myProfileProvider.overrideWith((ref) => Stream.value(profile)),
        dutyPeriodsProvider.overrideWith((ref) => Stream.value(periods)),
        dutyAssignmentsProvider.overrideWith((ref) => Stream.value(roster)),
      ],
    );
    addTearDown(c.dispose);
    c.listen(myDutyProvider, (_, _) {});
    // A signed-out myDutyProvider watches none of its inputs, and Riverpod
    // pauses an unlistened stream, so awaiting one below would hang.
    c.listen(nowProvider, (_, _) {});
    c.listen(dutyPeriodsProvider, (_, _) {});
    c.listen(dutyAssignmentsProvider, (_, _) {});
    clock.add(start);
    await c.read(nowProvider.future);
    await c.read(myProfileProvider.future);
    await c.read(dutyPeriodsProvider.future);
    await c.read(dutyAssignmentsProvider.future);
    return (c, clock);
  }

  test('on duty during my period, with who is on it with me', () async {
    final (c, _) = await container(start: DateTime(2026, 10, 7, 12));
    final duty = c.read(myDutyProvider);
    expect(duty.onDuty, isTrue);
    expect(duty.current?.id, 'now');
    expect(duty.coAssignees, ['jana']);
  });

  test('flips off at midnight by the clock alone', () async {
    final (c, clock) = await container(start: DateTime(2026, 10, 11, 23, 59));
    expect(c.read(myDutyProvider).onDuty, isTrue);

    clock.add(DateTime(2026, 10, 12, 0, 0));
    await Future<void>.delayed(Duration.zero);

    final duty = c.read(myDutyProvider);
    expect(duty.onDuty, isFalse);
    expect(duty.current, isNull);
    expect(duty, MyDuty.none);
  });

  test('a minute tick within the same day does not notify', () async {
    final (c, clock) = await container(start: DateTime(2026, 10, 7, 12));
    var notified = 0;
    c.listen(myDutyProvider, (_, _) => notified++);

    clock.add(DateTime(2026, 10, 7, 12, 1));
    await Future<void>.delayed(Duration.zero);

    expect(notified, 0);
  });

  test('a duty next week: not on duty today, its days are mine already',
      () async {
    final (c, _) = await container(
      start: DateTime(2026, 10, 7, 12),
      roster: const [DutyAssignment(periodId: 'next', userId: 'me')],
    );
    final duty = c.read(myDutyProvider);
    expect(duty.onDuty, isFalse);
    expect([for (final p in duty.mine) p.id], ['next']);
    expect(duty.coversDay(Day(2026, 10, 12)), isTrue);
    expect(duty.coversDay(Day(2026, 10, 18)), isTrue);
    expect(duty.coversDay(Day(2026, 10, 7)), isFalse);
    expect(duty.coversDay(Day(2026, 10, 19)), isFalse);
  });

  test('the days I may edit follow the clock: a period over drops out',
      () async {
    final (c, clock) = await container(
      start: DateTime(2026, 10, 11, 23, 59),
      roster: const [
        DutyAssignment(periodId: 'now', userId: 'me'),
        DutyAssignment(periodId: 'next', userId: 'me'),
      ],
    );
    expect(c.read(myDutyProvider).coversDay(Day(2026, 10, 11)), isTrue);

    clock.add(DateTime(2026, 10, 12, 0, 0));
    await Future<void>.delayed(Duration.zero);

    final duty = c.read(myDutyProvider);
    expect(duty.onDuty, isTrue);
    expect(duty.current?.id, 'next');
    expect([for (final p in duty.mine) p.id], ['next']);
    expect(duty.coversDay(Day(2026, 10, 11)), isFalse);
    expect(duty.coversDay(Day(2026, 10, 12)), isTrue);
  });

  test('signed out (no profile): none', () async {
    final (c, _) = await container(profile: null, start: DateTime(2026, 10, 7));
    expect(c.read(myDutyProvider), MyDuty.none);
  });
}
