import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/public_week.dart';
import 'package:rezervator/features/public/public_schedule_screen.dart';
import 'package:rezervator/features/schedule/day_pager_view.dart';
import 'package:rezervator/features/schedule/week_calendar_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // Pinned clock: Wednesday morning, the block at 10:00 not yet past.
  final now = DateTime(2026, 9, 9, 8, 0);
  final monday = Day(2026, 9, 7);

  final week = PublicWeek.fromJson({
    'tenant_name': 'Kuželna Test',
    'settings': {
      'lane_count': 2,
      'training_weekdays': [1, 2, 3, 4, 5, 6, 7],
      'booking_horizon_days': 14,
      'max_active_reservations': 3,
    },
    'blocks': [
      {'id': 'b1', 'starts_at': '10:00:00', 'ends_at': '11:00:00', 'position': 0, 'active': true},
    ],
    'slot_types': [
      {'id': 't-match', 'name': 'Zápas', 'is_match': true, 'builtin': true},
    ],
    'priority_slots': [
      {
        'id': 'm1', 'date': '2026-09-11', 'starts_at': '10:00:00', 'ends_at': '11:00:00',
        'type_id': 't-match', 'home_team': 'Sokol', 'away_team': 'Slavia',
      },
    ],
    'rentals': [
      {
        'id': 'r1', 'renter_name': '', 'lanes': [2], 'date': '2026-09-10',
        'starts_at': '10:00:00', 'ends_at': '11:00:00',
      },
    ],
    'occupied': [
      {'block_id': 'b1', 'date': '2026-09-09', 'lane': 1, 'club_color': 3},
    ],
  });

  void surface(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget app({
    List<(String, Day)>? requested,
    Object? error,
  }) =>
      ProviderScope(
        overrides: [
          nowProvider.overrideWith((ref) => Stream.value(now)),
          publicWeekProvider.overrideWith((ref, key) async {
            requested?.add(key);
            if (error != null) throw error;
            return week;
          }),
        ],
        child: const MaterialApp(home: PublicScheduleScreen(slug: 'test')),
      );

  testWidgets('landscape: the week calendar with Obsazeno, the match and the alley name',
      (tester) async {
    surface(tester, const Size(1600, 1200));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.byType(WeekCalendarView), findsOneWidget);
    expect(find.text('Kuželna Test'), findsOneWidget);
    // The reservation and the rental — both only „Obsazeno".
    expect(find.text('Obsazeno'), findsNWidgets(2));
    expect(find.textContaining('Sokol'), findsWidgets);
  });

  testWidgets('portrait: the day pager', (tester) async {
    surface(tester, const Size(900, 1600));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byType(DayPagerView), findsOneWidget);
  });

  testWidgets('tapping an occupied cell does nothing', (tester) async {
    surface(tester, const Size(1600, 1200));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Obsazeno').first);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('the arrow asks for the next Monday', (tester) async {
    surface(tester, const Size(1600, 1200));
    final requested = <(String, Day)>[];
    await tester.pumpWidget(app(requested: requested));
    await tester.pumpAndSettle();
    // The very first frame builds before the pinned clock's Stream.value
    // lands (it fires on a microtask, after that frame) — same
    // `nowProvider.value ?? DateTime.now()` fallback WeekScreen uses, so it
    // can briefly request the real wall clock's Monday before settling on
    // the pinned one. What matters here is where it settles.
    expect(requested.last, ('test', monday));

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(requested.last, ('test', monday.addDays(7)));
  });

  testWidgets('an unknown or switched-off slug says so', (tester) async {
    surface(tester, const Size(1600, 1200));
    await tester.pumpWidget(app(error: Exception('unknown_tenant')));
    await tester.pumpAndSettle();
    expect(find.text('Tahle kuželna veřejný přehled nemá.'), findsOneWidget);
  });
}
