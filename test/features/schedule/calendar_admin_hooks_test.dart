import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/schedule/schedule_callbacks.dart';

/// CalendarAdminHooks.forDay (0050): the block gestures are the player on
/// duty's only on the days of their own periods, so every view asks the
/// hooks per day. Nothing here draws a widget.
void main() {
  final thursday = Day(2026, 9, 10);
  final friday = Day(2026, 9, 11);

  // Every gesture set, so a test can tell which ones survive a day.
  CalendarAdminHooks all({bool Function(Day)? canEditDay}) =>
      CalendarAdminHooks(
        onEditBlock: (_, _) {},
        onAddBlockInGap: (_, _, _) {},
        onAddForDay: (_) {},
        onEditPrioritySlot: (_, _) {},
        onEditRental: (_, _) {},
        onMoveBlock: (_, _, _) {},
        onMovePrioritySlot: (_, _, _) {},
        onCloseDay: (_) {},
        onRestoreDay: (_) {},
        hasDayOverride: (day) => day == thursday,
        canEditDay: canEditDay ?? (_) => true,
      );

  test('by default every day is editable: the hooks come back as they are',
      () {
    final hooks = all();
    expect(hooks.canEditDay(thursday), isTrue);
    expect(identical(hooks.forDay(thursday), hooks), isTrue);
    expect(identical(hooks.forDay(friday), hooks), isTrue);
  });

  test('a day that is not editable loses the six block gestures', () {
    final hooks = all(canEditDay: (day) => day == thursday);
    expect(identical(hooks.forDay(thursday), hooks), isTrue);

    final other = hooks.forDay(friday);
    expect(other.onEditBlock, isNull);
    expect(other.onAddBlockInGap, isNull);
    expect(other.onAddForDay, isNull);
    expect(other.onMoveBlock, isNull);
    expect(other.onCloseDay, isNull);
    expect(other.onRestoreDay, isNull);
  });

  test('the other hooks stay on such a day, the predicate too', () {
    final hooks = all(canEditDay: (day) => day == thursday);
    final other = hooks.forDay(friday);
    expect(other.onEditPrioritySlot, isNotNull);
    expect(other.onEditRental, isNotNull);
    expect(other.onMovePrioritySlot, isNotNull);
    expect(other.hasDayOverride(thursday), isTrue);
    expect(other.canEditDay(thursday), isTrue);
    expect(other.canEditDay(friday), isFalse);
  });

  test('the read-only board offers nothing on any day', () {
    final none = CalendarAdminHooks.none.forDay(thursday);
    expect(none.onEditBlock, isNull);
    expect(none.onAddForDay, isNull);
    expect(none.onCloseDay, isNull);
    expect(none.onEditPrioritySlot, isNull);
  });
}
