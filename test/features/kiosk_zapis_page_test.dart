import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/features/kiosk/kiosk_zapis_page.dart';

import '../support/rudna_vrsovice.dart';

void main() {
  testWidgets('the kiosk\'s Zápis shows the players\' registration numbers '
      'too', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final first = rudnaPlayers.first.playerSlug!;
    var asked = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          matchResultsProvider.overrideWith(
            (ref) => Stream.value({rudnaSlot.id: rudnaResult}),
          ),
          matchPlayerResultsProvider.overrideWith(
            (ref, id) => Stream.value(rudnaPlayers),
          ),
          matchRegnumsProvider.overrideWith((ref, key) async {
            asked++;
            return {first: '787'};
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showKioskZapis(
                  context,
                  slot: rudnaSlot,
                  brightness: Brightness.light,
                  percent: 100,
                  onTouch: () {},
                ),
                child: const Text('Zápis'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Zápis'));
    await tester.pumpAndSettle();

    expect(asked, greaterThan(0));
    expect(find.text('787'), findsOneWidget);
  });
}
