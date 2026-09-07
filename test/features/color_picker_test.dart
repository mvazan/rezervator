import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/palette.dart';
import 'package:rezervator/features/admin/widgets/color_picker.dart';

void main() {
  testWidgets('tapping a swatch reports its palette index', (tester) async {
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ColorPickerGrid(
            selected: -1,
            onChanged: (index) => selected = index,
          ),
        ),
      ),
    );

    // Swatches are laid out none-option first, then indices 0..11 — tap the
    // third rendered circle avatar-like InkWell, i.e. palette index 1.
    final swatches = find.byType(InkWell);
    await tester.tap(swatches.at(2));
    await tester.pump();

    expect(selected, 1);
  });

  testWidgets('tapping the none option reports noneValue', (tester) async {
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ColorPickerGrid(
            selected: 3,
            noneValue: -2,
            onChanged: (index) => selected = index,
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.block));
    await tester.pump();

    expect(selected, -2);
  });

  testWidgets('the selected swatch is marked with a check and a ring, '
      'the others with neither', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ColorPickerGrid(selected: 1, onChanged: (_) {}),
        ),
      ),
    );

    // Exactly one check, and it sits in the chosen swatch — not a ring
    // colour that a blue swatch can swallow.
    expect(find.byIcon(Icons.check), findsOneWidget);
    final swatches = find.byType(InkWell);
    expect(
      find.descendant(of: swatches.at(2), matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    // The "none" option keeps its own icon while something else is chosen.
    expect(find.byIcon(Icons.block), findsOneWidget);
  });

  testWidgets('the none option selected shows the check, not the block icon',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ColorPickerGrid(selected: -1, onChanged: (_) {}),
        ),
      ),
    );

    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.byIcon(Icons.block), findsNothing);
  });

  testWidgets('nothing selected marks no swatch', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ColorPickerGrid(selected: 99, onChanged: (_) {}),
        ),
      ),
    );

    expect(find.byIcon(Icons.check), findsNothing);
  });

  group('the wheel swatch', () {
    Future<void> pump(WidgetTester tester, int selected,
        void Function(int) onChanged) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ColorPickerGrid(selected: selected, onChanged: onChanged),
        ),
      ));
    }

    testWidgets('sits last and opens the picker', (tester) async {
      await pump(tester, -1, (_) {});

      // none + 9 palette entries + the wheel.
      expect(find.byType(InkWell), findsNWidgets(11));
      await tester.tap(find.byType(InkWell).last);
      await tester.pumpAndSettle();

      expect(find.text('Vlastní barva'), findsWidgets);
    });

    testWidgets('a confirmed colour comes back packed', (tester) async {
      int? reported;
      await pump(tester, -1, (v) => reported = v);

      await tester.tap(find.byType(InkWell).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(reported, isNotNull);
      expect(isCustomColor(reported!), isTrue);
    });

    testWidgets('cancelling leaves the selection alone', (tester) async {
      int? reported;
      await pump(tester, 3, (v) => reported = v);

      await tester.tap(find.byType(InkWell).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(reported, isNull);
    });

    testWidgets('a hand-picked selection shows on the swatch, not the wheel',
        (tester) async {
      final value = packCustomColor(const Color(0xFF3366CC));
      await pump(tester, value, (_) {});

      // The check mark marks the selected swatch — the wheel one here.
      expect(find.byIcon(Icons.check), findsOneWidget);
    });
  });
}
