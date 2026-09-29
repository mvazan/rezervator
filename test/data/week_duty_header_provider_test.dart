import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';

/// weekDutyHeaderProvider (0050) is a family keyed by the week's Monday:
/// every week swiped past adds an instance, so it must be autoDispose or
/// they pile up for the whole session.
void main() {
  test('a week nobody watches any more is disposed', () async {
    final c = ProviderContainer(
      overrides: [
        nowProvider.overrideWith(
          (ref) => Stream.value(DateTime(2026, 10, 7, 12)),
        ),
        myProfileProvider.overrideWith((ref) => Stream.value(null)),
        playersProvider.overrideWith((ref) async => const <PlayerName>[]),
        dutyPeriodsProvider.overrideWith(
          (ref) => Stream.value(const <DutyPeriod>[]),
        ),
        dutyAssignmentsProvider.overrideWith(
          (ref) => Stream.value(const <DutyAssignment>[]),
        ),
      ],
    );
    addTearDown(c.dispose);
    final week = weekDutyHeaderProvider(Day(2026, 10, 5));

    final sub = c.listen(week, (_, _) {});
    expect(c.exists(week), isTrue);

    sub.close();
    await c.pump();
    expect(c.exists(week), isFalse);
  });
}
