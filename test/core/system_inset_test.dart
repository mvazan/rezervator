import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart';

/// The app draws under the navigation bar: a scrollable with an explicit
/// `padding` must add the bar's height to its bottom, or its last rows stay
/// under the bar (the three-button navigation of an Android phone).
void main() {
  Widget host(Widget child, {double bar = 0}) => MediaQuery(
        data: MediaQueryData(padding: EdgeInsets.only(bottom: bar)),
        child: MaterialApp(home: Scaffold(body: child)),
      );

  testWidgets('padWithSystemInset adds the inset to the bottom only',
      (tester) async {
    late EdgeInsets padded;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(padding: EdgeInsets.only(bottom: 48)),
        child: Builder(
          builder: (context) {
            padded = padWithSystemInset(context, const EdgeInsets.all(12));
            return const SizedBox();
          },
        ),
      ),
    );
    expect(padded, const EdgeInsets.fromLTRB(12, 12, 12, 60));
  });

  testWidgets('no inset, no change', (tester) async {
    late EdgeInsets padded;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Builder(
          builder: (context) {
            padded = padWithSystemInset(context, const EdgeInsets.all(12));
            return const SizedBox();
          },
        ),
      ),
    );
    expect(padded, const EdgeInsets.all(12));
  });

  testWidgets('a list scrolled to its end clears the bar', (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => ListView(
            padding: padWithSystemInset(context, const EdgeInsets.all(12)),
            children: [
              for (var i = 0; i < 30; i++) SizedBox(height: 50, child: Text('r$i')),
            ],
          ),
        ),
        bar: 48,
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -5000));
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(find.text('r29')).dy, lessThanOrEqualTo(600 - 48));
  });
}
