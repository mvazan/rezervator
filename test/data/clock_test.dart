import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';

void main() {
  test('minuteClock emits now, then only when the minute changes', () async {
    var t = DateTime(2026, 9, 2, 17, 30, 10);
    final seen = <DateTime>[];
    final sub = minuteClock(
      clock: () => t,
      poll: const Duration(milliseconds: 10),
    ).listen(seen.add);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(seen, [DateTime(2026, 9, 2, 17, 30, 10)]);

    // Same minute: polls fire, nothing is emitted.
    t = DateTime(2026, 9, 2, 17, 30, 50);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(seen.length, 1);

    // Minute boundary crossed: exactly one fresh value.
    t = DateTime(2026, 9, 2, 17, 31, 5);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(seen.length, 2);
    expect(seen.last.minute, 31);

    // Day change with the same hour:minute still counts as a change.
    t = DateTime(2026, 9, 3, 17, 31, 5);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(seen.length, 3);
    await sub.cancel();
  });
}
