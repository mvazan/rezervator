import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/schedule_screen.dart';

/// Smoke test for the admin Rozvrh screen: the settings form seeds itself
/// from the settings stream (which delivers AFTER the first build), the
/// block list renders and the generator dialog opens.
void main() {
  const admin = Profile(
    id: 'admin1',
    displayName: 'Správce',
    email: 'admin@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );
  const settings = ScheduleSettings(
    laneCount: 6,
    trainingWeekdays: {1, 2, 4},
    bookingHorizonDays: 21,
    maxActiveReservations: 3,
    tenantId: 't1',
  );
  const b1 = TimeBlock(
    id: 'b1',
    startsAt: HourMinute(16, 0),
    endsAt: HourMinute(17, 0),
    position: 0,
    active: true,
  );
  const b2 = TimeBlock(
    id: 'b2',
    startsAt: HourMinute(17, 0),
    endsAt: HourMinute(18, 0),
    position: 1,
    active: true,
  );

  Widget app() => ProviderScope(
        overrides: [
          myProfileProvider.overrideWith((ref) => Stream.value(admin)),
          settingsProvider.overrideWith((ref) => Stream.value(settings)),
          timeBlocksProvider.overrideWith(
            (ref) => Stream.value(const [b1, b2]),
          ),
        ],
        child: const MaterialApp(home: ScheduleAdminScreen()),
      );

  String fieldText(WidgetTester tester, String label) =>
      tester.widget<TextField>(find.widgetWithText(TextField, label))
          .controller!
          .text;

  bool chipSelected(WidgetTester tester, String label) =>
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, label))
          .selected;

  testWidgets('renders the settings form seeded from the stream and lists '
      'the blocks', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Rozvrh'), findsOneWidget);
    expect(fieldText(tester, 'Počet drah'), '6');
    expect(fieldText(tester, 'Rezervace dopředu (dní)'), '21');
    expect(fieldText(tester, 'Max. aktivních rezervací na hráče'), '3');
    // Weekday chips follow trainingWeekdays {po, út, čt}.
    expect(chipSelected(tester, 'po'), isTrue);
    expect(chipSelected(tester, 'út'), isTrue);
    expect(chipSelected(tester, 'st'), isFalse);
    expect(chipSelected(tester, 'čt'), isTrue);

    expect(find.text('Tréninkové bloky'), findsOneWidget);
    expect(find.text('16:00–17:00'), findsOneWidget);
    expect(find.text('17:00–18:00'), findsOneWidget);
    expect(find.text('Zatím žádné bloky.'), findsNothing);
  });

  testWidgets('the generator dialog opens from its button', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Vygenerovat bloky'));
    await tester.pumpAndSettle();

    expect(find.text('Vygenerovat bloky'), findsOneWidget);
    expect(find.text('Začátek'), findsOneWidget);
    expect(find.text('Vytvořit'), findsOneWidget);
  });
}
