import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/hub_menu.dart';

/// HubMenu's optional per-entry badge (0051 — Nástěnka/Zprávy unread
/// counts): a count on the icon in both layouts, nothing without one.
void main() {
  HubEntry entry({int? badge}) => (
        label: 'Zprávy',
        icon: Icons.forum_outlined,
        subtitle: null,
        badge: badge,
        onTap: () {},
      );

  testWidgets('a badge count renders next to the icon, narrow layout', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(
        width: 400, height: 600,
        child: HubMenu(entries: [entry(badge: 3)]),
      )),
    ));
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('no badge means no number shown', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(
        width: 400, height: 600,
        child: HubMenu(entries: [entry()]),
      )),
    ));
    expect(find.byType(Badge), findsNothing);
  });

  testWidgets('badge renders in the wide grid layout too', (tester) async {
    // The default 800×600 test view would clamp the 1000-wide box below
    // the 840 breakpoint — widen the view so the grid really renders.
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(
        width: 1000, height: 600,
        child: HubMenu(entries: [entry(badge: 1)]),
      )),
    ));
    expect(find.byType(GridView), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });
}
