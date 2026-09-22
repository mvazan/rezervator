/// The public week board at `#/prehled/<slug>` (0043): anyone, no sign-in,
/// read-only. The same board as the app ([WeekBoard]), fed by ONE call,
/// `public_week`, which hands out no names — an occupied lane is a bare
/// cell that reads „Obsazeno" in the player's club colour.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/schedule.dart';
import '../admin/widgets/admin_scaffold.dart' show AsyncBody;
import '../schedule/schedule_callbacks.dart';
import '../schedule/week_board.dart';
import '../schedule/widgets/week_range_nav.dart';

/// The public board's own wording for a slug that answers nothing — unknown
/// and switched off look the same on purpose (the server does not say which).
String publicWeekError(Object error) =>
    error.toString().contains('unknown_tenant')
        ? 'Tahle kuželna veřejný přehled nemá.'
        : friendlyDbError(error);

class PublicScheduleScreen extends ConsumerStatefulWidget {
  const PublicScheduleScreen({super.key, required this.slug});

  final String slug;

  @override
  ConsumerState<PublicScheduleScreen> createState() =>
      _PublicScheduleScreenState();
}

class _PublicScheduleScreenState extends ConsumerState<PublicScheduleScreen>
    with WeekNavigation {
  /// Nothing on this board reacts to a tap (it is never interactive, and
  /// there is no signed-in player) — the callbacks only fill the contract.
  static final _inert = SlotCallbacks(
    onBook: (_, _, _) {},
    onCancel: (_, _, _, {required ownFuture}) {},
  );

  /// Kept across weeks, so the title does not blink while the next week
  /// loads.
  String? _tenantName;

  @override
  Widget build(BuildContext context) {
    final nowDt = ref.watch(nowProvider).value ?? DateTime.now();
    final today = Day.fromDateTime(nowDt);
    final now = HourMinute(nowDt.hour, nowDt.minute);
    final monday = mondayOf(today);
    final key = (widget.slug, monday);
    final value = ref.watch(publicWeekProvider(key));
    _tenantName = value.value?.tenantName ?? _tenantName;

    return Scaffold(
      // The week range sits as the AppBar's own second line — centred under
      // the alley name, not a separate app-branded strip below it (that was
      // [WeekHeader]'s job for the signed-in app, whose "Rezervátor" title
      // makes no sense repeated here under the alley's own name).
      appBar: AppBar(
        title: Text(_tenantName ?? 'Rozvrh'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: WeekRangeNav(
            monday: monday,
            weekOffset: weekOffset,
            onGo: goWeek,
          ),
        ),
      ),
      body: AsyncBody(
        value: value,
        errorText: publicWeekError,
        onRetry: () => ref.invalidate(publicWeekProvider(key)),
        builder: (pw) => WeekBoard(
          week: buildWeekSchedule(
            monday: monday,
            today: today,
            now: now,
            settings: pw.settings,
            blocks: pw.blocks,
            overrides: pw.overrides,
            priority: pw.prioritySlots,
            rentals: pw.rentals,
            reservations: pw.reservations,
          ),
          weekOffset: weekOffset,
          dayIndex: dayIndex,
          today: today,
          now: now,
          settings: pw.settings,
          blocks: pw.blocks,
          overrides: pw.overrides,
          priority: pw.prioritySlots,
          rentals: pw.rentals,
          me: null,
          myCount: 0,
          myCountByIndex: const [0, 0, 0, 0, 0, 0, 0],
          nameById: pw.nameById,
          clubColorById: pw.clubColorById,
          interactive: false,
          slot: _inert,
          onSelectDay: selectDay,
          onShiftWeek: shiftWeek,
        ),
      ),
    );
  }
}
