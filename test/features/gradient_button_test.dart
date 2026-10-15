import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/theme.dart';
import 'package:rezervator/core/widgets/gradient_button.dart';

/// The gradient's cyan end drowns white text in a light theme — the label
/// must flip to deep indigo there and stay white in the dark theme.
void main() {
  Widget app(Brightness brightness) => MaterialApp(
        theme: buildTheme(brightness),
        home: Scaffold(
          body: Center(
            child: GradientButton(
              onPressed: () {},
              child: const Text('Rezervovat'),
            ),
          ),
        ),
      );

  Color labelColor(WidgetTester tester) {
    final context = tester.element(find.text('Rezervovat'));
    return DefaultTextStyle.of(context).style.color!;
  }

  testWidgets('light theme renders the label dark', (tester) async {
    await tester.pumpWidget(app(Brightness.light));
    await tester.pumpAndSettle();
    expect(labelColor(tester), const Color(0xFF1E1B4B));
  });

  testWidgets('dark theme keeps the label white', (tester) async {
    await tester.pumpWidget(app(Brightness.dark));
    await tester.pumpAndSettle();
    expect(labelColor(tester), Colors.white);
  });

  testWidgets('the gradient paints on the button\'s own Material: an opaque '
      'background under the button (the kiosk status bar) does not hide it',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Container(
            key: const ValueKey('bar'),
            color: Colors.grey,
            child: GradientButton(
              onPressed: () {},
              child: const Text('Rezervace tréninku'),
            ),
          ),
        ),
      ),
    );
    // The Material the Ink paints on is the nearest one above it; it must
    // sit above the opaque bar, not be the Scaffold's beneath it.
    final material = find
        .ancestor(of: find.byType(Ink), matching: find.byType(Material))
        .first;
    expect(
      find.descendant(of: find.byKey(const ValueKey('bar')), matching: material),
      findsOneWidget,
    );
    expect(tester.widget<Material>(material).type, MaterialType.transparency);
  });
}
