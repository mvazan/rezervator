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
}
