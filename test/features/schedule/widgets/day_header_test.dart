import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/text_size.dart';
import 'package:rezervator/core/theme.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/schedule/widgets/day_header.dart';

/// The date badge is a hard 34×34 box around a 9pt weekday + 13pt day-number
/// Column with no spare room: the system text scale composes with the
/// in-app "Velikost písma" choice (core/text_size.dart's [AppTextScaler]),
/// and system "Large" (1.15, Android's own default step) × "Největší"
/// (1.3) already reaches 1.495 — enough to overflow the badge from a
/// setting combination neither side considers extreme. See
/// day_header.dart's `_dateBadge`, wrapped in `MediaQuery.withNoTextScaling`
/// because it's fixed chrome, not scaling body text.
void main() {
  Future<void> pumpAt(
    WidgetTester tester,
    TextScaler systemScale,
    TextSizeChoice choice,
  ) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: AppTextScaler(systemScale, choice),
            ),
            child: DayHeader(
              date: Day(2026, 9, 7),
              priority: const [],
              chipLabel: '3 volných',
            ),
          ),
        ),
      ),
    ));
  }

  testWidgets(
      'date badge does not overflow at system "Large" (1.15) × '
      '"Největší" (1.3) — 1.495 combined', (tester) async {
    await pumpAt(
        tester, const TextScaler.linear(1.15), TextSizeChoice.largest);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'date badge does not overflow at system "Largest" (1.3) × '
      '"Největší" (1.3) — 1.69 combined', (tester) async {
    await pumpAt(
        tester, const TextScaler.linear(1.3), TextSizeChoice.largest);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'date badge does not overflow at the 200% design-size cap',
      (tester) async {
    await pumpAt(tester, const TextScaler.linear(4.0), TextSizeChoice.largest);
    expect(tester.takeException(), isNull);
  });
}
