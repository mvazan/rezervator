import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/kiosk/kiosk_duty.dart';

/// kioskDutyPlanProvider (0073): who serves now and who comes next, for the
/// kiosk's status-bar line, its dialog and the drawer's card. The kiosk
/// runs all week, so the plan must flip at midnight by the app clock alone
/// — no duty, assignment or player row changes then.
void main() {
  // Anna's duty ends on Sunday, Bert's starts on Monday.
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
    DutyAssignment(periodId: 'now', userId: 'a'),
    DutyAssignment(periodId: 'next', userId: 'b'),
  ];
  const players = [
    PlayerName(id: 'a', displayName: 'Anna'),
    PlayerName(id: 'b', displayName: 'Bert'),
  ];

  Future<(ProviderContainer, StreamController<DateTime>)> container({
    required DateTime start,
  }) async {
    final clock = StreamController<DateTime>();
    addTearDown(clock.close);
    final c = ProviderContainer(
      overrides: [
        nowProvider.overrideWith((ref) => clock.stream),
        dutyPeriodsProvider.overrideWith((ref) => Stream.value(periods)),
        dutyAssignmentsProvider.overrideWith(
          (ref) => Stream.value(assignments),
        ),
        playersProvider.overrideWith((ref) async => players),
      ],
    );
    addTearDown(c.dispose);
    c.listen(kioskDutyPlanProvider, (_, _) {});
    // Kept alive on their own: a plan that stopped watching the clock must
    // fail the expectations below, not hang on a paused stream.
    c.listen(nowProvider, (_, _) {});
    c.listen(dutyPeriodsProvider, (_, _) {});
    c.listen(dutyAssignmentsProvider, (_, _) {});
    c.listen(playersProvider, (_, _) {});
    clock.add(start);
    await c.read(nowProvider.future);
    await c.read(dutyPeriodsProvider.future);
    await c.read(dutyAssignmentsProvider.future);
    await c.read(playersProvider.future);
    return (c, clock);
  }

  test('flips at midnight by the clock alone', () async {
    final (c, clock) = await container(start: DateTime(2026, 10, 11, 23, 59));
    var plan = c.read(kioskDutyPlanProvider);
    expect(plan.now?.who, 'Anna');
    expect([for (final e in plan.next) e.who], ['Bert']);

    clock.add(DateTime(2026, 10, 12, 0, 0));
    await Future<void>.delayed(Duration.zero);

    plan = c.read(kioskDutyPlanProvider);
    expect(plan.now?.who, 'Bert');
    expect(plan.next, isEmpty);
  });

  test('a minute tick within the same day does not notify', () async {
    final (c, clock) = await container(start: DateTime(2026, 10, 8, 12));
    var notified = 0;
    c.listen(kioskDutyPlanProvider, (_, _) => notified++);

    clock.add(DateTime(2026, 10, 8, 12, 1));
    await Future<void>.delayed(Duration.zero);

    expect(notified, 0);
    expect(c.read(kioskDutyPlanProvider).now?.who, 'Anna');
  });
}
