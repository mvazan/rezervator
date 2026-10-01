import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/app_scroll_behavior.dart';

void main() {
  for (final kind in [
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.touch,
  ]) {
    testWidgets('a $kind drag scrolls a list', (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          scrollBehavior: const AppScrollBehavior(),
          home: ListView(
            controller: controller,
            children: [
              for (var i = 0; i < 50; i++)
                SizedBox(height: 80, child: Text('$i')),
            ],
          ),
        ),
      );
      final gesture = await tester.startGesture(
        const Offset(200, 300),
        kind: kind,
      );
      await gesture.moveBy(const Offset(0, -200));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
    });
  }
}
