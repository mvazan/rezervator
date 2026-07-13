import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
