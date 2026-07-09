import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/schedule/home_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // HomeShell embeds WeekScreen, which reads the schedule_view preference on
  // its first frame — a mock handler is required or pumpAndSettle hangs.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const settings = ScheduleSettings(
    laneCount: 1,
    trainingWeekdays: {1, 2, 3, 4, 5, 6, 7},
    bookingHorizonDays: 14,
    maxActiveReservations: 3,
  );

  const me = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    club: '',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );

  Widget app() => ProviderScope(
    overrides: [
      settingsProvider.overrideWith((ref) => Stream.value(settings)),
      timeBlocksProvider.overrideWith((ref) => Stream.value(const [])),
      dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
      matchesProvider.overrideWith((ref) => Stream.value(const [])),
      rentalsProvider.overrideWith((ref) => Stream.value(const [])),
      weekReservationsProvider.overrideWith(
        (ref, monday) => StreamController<List<Reservation>>().stream,
      ),
      myActiveReservationsProvider.overrideWith(
        (ref) => Stream.value(const []),
      ),
      myProfileProvider.overrideWith((ref) => Stream.value(me)),
      playersProvider.overrideWith((ref) async => const []),
    ],
    child: const MaterialApp(home: HomeShell()),
  );

  testWidgets('AppBar has no logout icon; profile icon is the entry point', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    // Logout now lives on the profile screen, not the AppBar.
    expect(find.byIcon(Icons.logout), findsNothing);
    expect(find.byIcon(Icons.account_circle_outlined), findsOneWidget);
  });
}
