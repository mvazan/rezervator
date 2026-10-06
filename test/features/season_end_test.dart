import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/features/clubhouse/widgets/season_end.dart';

void main() {
  Widget host({double spacer = 0}) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        key: const Key('list'),
        child: Column(children: [SizedBox(height: spacer), const SeasonEnd()]),
      ),
    ),
  );

  testWidgets('says it is the end and points to Termínátor', (tester) async {
    await tester.pumpWidget(host());
    expect(find.text('You made it to the end!'), findsOneWidget);
    expect(find.text('Termínátor – appka na turnaje'), findsOneWidget);
    expect(find.text('Zdarma na Google Play'), findsOneWidget);
    expect(
      terminatorPlayUrl,
      'https://play.google.com/store/apps/details?id=cz.kuzelky.terminator',
    );
  });

  testWidgets('the hands clap once they are on screen, then rest', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    // On screen from the start: the clap runs and settles.
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('below the fold nothing runs until it is scrolled to', (
    tester,
  ) async {
    await tester.pumpWidget(host(spacer: 3000));
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);

    await tester.drag(find.byKey(const Key('list')), const Offset(0, -2800));
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('with animations off the hands just rest', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: host(),
      ),
    );
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
  });
}
