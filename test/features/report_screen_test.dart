import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart' show monthsFull, today;
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/report_screen.dart';

/// Smoke test for the attendance report: renders the current month's rows
/// for an admin, shows its empty state, and the month arrows re-key
/// attendanceProvider (the export is never tapped — FileSaver is a plugin).
void main() {
  const admin = Profile(
    id: 'admin1',
    displayName: 'Správce',
    email: 'admin@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );

  const rows = [
    AttendanceRow(
        playerId: 'p1', displayName: 'Zdeněk', club: 'Veverky', attended: 3),
    AttendanceRow(
        playerId: 'p2', displayName: 'Blanka', club: 'Veverky', attended: 2),
    AttendanceRow(playerId: 'p3', displayName: 'Adam', club: '', attended: 1),
  ];

  String label(int year, int month) => '„${monthsFull[month]} $year“';

  // One ProviderScope per test: a second pumpWidget does not swap overrides.
  Widget app(List<AttendanceRow> rows, {List<(int, int)>? requested}) =>
      ProviderScope(
        overrides: [
          myProfileProvider.overrideWith((ref) => Stream.value(admin)),
          attendanceProvider.overrideWith((ref, ym) async {
            requested?.add(ym);
            return rows;
          }),
        ],
        child: const MaterialApp(home: ReportScreen()),
      );

  FilledButton exportButton(WidgetTester tester) =>
      tester.widget(find.widgetWithText(FilledButton, 'Export CSV'));

  testWidgets('renders the title, the current month and the rows by club',
      (tester) async {
    final now = today();
    await tester.pumpWidget(app(rows));
    await tester.pumpAndSettle();

    expect(find.text('Docházka'), findsOneWidget);
    expect(find.text(label(now.year, now.month)), findsOneWidget);
    expect(find.text('Veverky — 5× / 2 hráči'), findsOneWidget);
    expect(find.text('Zdeněk — 3×'), findsOneWidget);
    expect(find.text('Blanka — 2×'), findsOneWidget);
    expect(find.text('Bez oddílu — 1× / 1 hráč'), findsOneWidget);
    expect(find.text('Adam — 1×'), findsOneWidget);
    expect(exportButton(tester).onPressed, isNotNull);
  });

  testWidgets('shows the empty state without rows; export stays disabled',
      (tester) async {
    await tester.pumpWidget(app(const []));
    await tester.pumpAndSettle();

    expect(find.text('Docházka'), findsOneWidget);
    expect(find.text('Žádné rezervace v tomto měsíci.'), findsOneWidget);
    expect(exportButton(tester).onPressed, isNull);
  });

  testWidgets('the month arrows re-key the attendance provider',
      (tester) async {
    final now = today();
    final requested = <(int, int)>[];
    await tester.pumpWidget(app(rows, requested: requested));
    await tester.pumpAndSettle();
    expect(requested, [(now.year, now.month)]);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    final previous = now.month == 1 ? (now.year - 1, 12) : (now.year, now.month - 1);
    expect(find.text(label(previous.$1, previous.$2)), findsOneWidget);
    expect(requested.last, previous);
    expect(find.text('Zdeněk — 3×'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text(label(now.year, now.month)), findsOneWidget);
  });
}
