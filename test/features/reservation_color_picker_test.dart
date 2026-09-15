import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/palette.dart';
import 'package:rezervator/features/profile/widgets/reservation_color_picker.dart';

/// The reservation colour picker offers the Google palette (stored as a
/// packed RGB, like a hand-picked colour) plus "Podle oddílu"; the wheel is
/// the thirteenth swatch. Every non-none pick is a packed RGB, so nothing it
/// emits collides with a club palette index.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required int selected,
    required ValueChanged<int> onChanged,
  }) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ReservationColorPicker(selected: selected, onChanged: onChanged),
        ),
      ));

  testWidgets('a Google swatch is stored as its packed RGB, not a colorId',
      (tester) async {
    int? got;
    await pump(tester, selected: -1, onChanged: (c) => got = c);
    // Borůvková is colorId 9 on Google, RGB 0x3F51B5.
    await tester.tap(find.byTooltip('Borůvková'));
    await tester.pump();
    expect(got, packCustomColor(const Color(0xFF3F51B5)));
    expect(isCustomColor(got!), isTrue,
        reason: 'stored as a packed RGB, so it never means a club index');
  });

  testWidgets('a Google swatch shows the raw vivid colour, like the calendar '
      'picker — not a pale board tint', (tester) async {
    await pump(tester, selected: -1, onChanged: (_) {});
    // The inner coloured circle carries the fill (the outer is the ring).
    final fills = tester
        .widgetList<Container>(find.descendant(
            of: find.byTooltip('Borůvková'), matching: find.byType(Container)))
        .map((c) => (c.decoration as BoxDecoration).color)
        .toList();
    expect(fills, contains(const Color(0xFF3F51B5)));
  });

  testWidgets('the selected Google colour shows its check', (tester) async {
    await pump(
      tester,
      selected: packCustomColor(const Color(0xFF3F51B5)), // Borůvková
      onChanged: (_) {},
    );
    // The selected swatch renders a check icon under its tooltip.
    expect(
      find.descendant(
          of: find.byTooltip('Borůvková'), matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    // A different Google swatch is not selected.
    expect(
      find.descendant(
          of: find.byTooltip('Rajčatová'), matching: find.byIcon(Icons.check)),
      findsNothing,
    );
  });

  testWidgets('Podle oddílu emits -1', (tester) async {
    int? got;
    await pump(
      tester,
      selected: packCustomColor(const Color(0xFF3F51B5)),
      onChanged: (c) => got = c,
    );
    await tester.tap(find.byTooltip('Podle oddílu'));
    await tester.pump();
    expect(got, -1);
  });

  testWidgets('a hand-picked colour that is no Google preset shows as the '
      'wheel, not a preset', (tester) async {
    // A migrated old palette colour (Fialová 0x5B21B6) is a packed RGB that
    // matches no Google preset — the wheel swatch carries the selection.
    await pump(
      tester,
      selected: packCustomColor(const Color(0xFF5B21B6)),
      onChanged: (_) {},
    );
    expect(
      find.descendant(
          of: find.byTooltip('Vlastní barva'),
          matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    // And no Google preset steals the selection.
    for (final (_, name, _) in googleEventColors) {
      expect(
        find.descendant(
            of: find.byTooltip(name), matching: find.byIcon(Icons.check)),
        findsNothing,
        reason: '$name must not be selected for a non-preset custom colour',
      );
    }
  });
}
