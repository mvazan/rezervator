import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart';
import 'package:rezervator/domain/models.dart';

/// [pickDay]'s optional `selectable` predicate: the duty picks a day to edit
/// or to write about only among the days of their own periods.
void main() {
  Day? picked;
  var done = false;

  Widget host({
    required Day first,
    required Day last,
    Day? initial,
    bool Function(Day)? selectable,
  }) {
    picked = null;
    done = false;
    return MaterialApp(
      locale: const Locale('cs'),
      supportedLocales: const [Locale('cs')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            picked = await pickDay(
              context,
              initial: initial,
              first: first,
              last: last,
              selectable: selectable,
            );
            done = true;
          },
          child: const Text('open'),
        ),
      ),
    );
  }

  bool tenToTwelve(Day d) => d.month == 10 && d.day >= 10 && d.day <= 12;

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a day the predicate refuses cannot be picked', (tester) async {
    await tester.pumpWidget(host(
      first: Day(2026, 10, 1),
      last: Day(2026, 10, 31),
      initial: Day(2026, 10, 11),
      selectable: tenToTwelve,
    ));
    await open(tester);
    await tester.tap(find.text('13')); // refused: nothing happens
    await tester.pump();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(picked, Day(2026, 10, 11));
  });

  testWidgets('a day it allows can be picked', (tester) async {
    await tester.pumpWidget(host(
      first: Day(2026, 10, 1),
      last: Day(2026, 10, 31),
      initial: Day(2026, 10, 11),
      selectable: tenToTwelve,
    ));
    await open(tester);
    await tester.tap(find.text('12'));
    await tester.pump();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(picked, Day(2026, 10, 12));
  });

  testWidgets('an initial day the predicate refuses opens on the nearest '
      'allowed one instead of asserting', (tester) async {
    await tester.pumpWidget(host(
      first: Day(2026, 10, 1),
      last: Day(2026, 10, 31),
      initial: Day(2026, 10, 20),
      selectable: tenToTwelve,
    ));
    await open(tester);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(picked, Day(2026, 10, 12));
  });

  testWidgets('no allowed day at all: no picker, no answer', (tester) async {
    await tester.pumpWidget(host(
      first: Day(2026, 10, 1),
      last: Day(2026, 10, 31),
      selectable: (_) => false,
    ));
    await open(tester);
    expect(find.text('OK'), findsNothing);
    expect(done, isTrue);
    expect(picked, isNull);
  });

  testWidgets('without a predicate every day of the range is open', (tester) async {
    await tester.pumpWidget(host(
      first: Day(2026, 10, 1),
      last: Day(2026, 10, 31),
      initial: Day(2026, 10, 11),
    ));
    await open(tester);
    await tester.tap(find.text('13'));
    await tester.pump();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(picked, Day(2026, 10, 13));
  });
}
