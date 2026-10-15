import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/kiosk/kiosk_headline.dart';
import 'package:rezervator/features/kiosk/kiosk_new_chip.dart';

/// The notice titles in the kiosk's status bar take turns with a cross-fade.
/// The next title fades in where it will stay and the last one fades out
/// where it was: when the fade is over, nothing jumps.
void main() {
  Message notice(String id, String title, {DateTime? posted}) => Message(
    id: id,
    kind: MessageKind.notice,
    audience: MessageAudience.all,
    authorId: 'a',
    authorRole: MessageAuthorRole.admin,
    onDate: null,
    blockId: null,
    title: title,
    body: 'Sejdeme se v devět.',
    expiresAt: null,
    notify: true,
    createdAt: posted ?? DateTime(2026, 9, 1),
    updatedAt: posted ?? DateTime(2026, 9, 1),
  );

  // Thursday noon: a notice posted the day before is fresh (for 3 days by
  // default), one of September is not.
  final now = DateTime(2026, 10, 8, 12);
  final yesterday = DateTime(2026, 10, 7, 12);

  Widget app(
    List<Message> notices, {
    double width = 900,
    KioskNoticesFresh fresh = KioskNoticesFresh.highlight,
    int freshDays = 3,
    void Function(Message)? onOpen,
  }) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: KioskHeadline(
            notices: notices,
            turn: const Duration(seconds: 5),
            now: now,
            fresh: fresh,
            freshDays: freshDays,
            onOpen: onOpen ?? (_) {},
          ),
        ),
      ),
    ),
  );

  testWidgets('a turn fades the next title in where it stays and the last '
      'one out where it was', (tester) async {
    const long = 'Zámek kuželny se mění v pondělí';
    const short = 'Brigáda';
    final opened = <String>[];
    await tester.pumpWidget(
      app(
        [notice('1', long), notice('2', short)],
        onOpen: (m) => opened.add(m.id),
      ),
    );

    // From the notice titled [from] to the one titled [to], numbered
    // [counter]: half way through the fade both are on screen, each where
    // it is before and after the fade.
    Future<void> turn(String from, String to, String counter) async {
      final fromAt = tester.getCenter(find.text(from));
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getCenter(find.text(from)), fromAt);
      final toAt = tester.getCenter(find.text(to));
      final counterAt = tester.getCenter(find.text(counter));
      await tester.pumpAndSettle();
      expect(find.text(from), findsNothing);
      expect(tester.getCenter(find.text(to)), toAt);
      expect(tester.getCenter(find.text(counter)), counterAt);
      // And where it stays is the middle of the bar: icon, title and
      // counter centred together (the padding is the same on both sides).
      final line = find.ancestor(of: find.text(to), matching: find.byType(Row));
      expect(
        tester.getCenter(line.first).dx,
        closeTo(tester.getCenter(find.byType(KioskHeadline)).dx, 0.5),
      );
    }

    await turn(long, short, '2/2');
    await turn(short, long, '1/2');

    // A tap opens the notice shown.
    await tester.tap(find.text(long));
    expect(opened, ['1']);
  });

  testWidgets('a long title ends in an ellipsis, the counter stays in the '
      'bar', (tester) async {
    await tester.pumpWidget(
      app(
        [
          notice('1', 'Zámek kuželny se mění v pondělí, klíče jsou u správce'),
          notice('2', 'Brigáda'),
        ],
        width: 400,
      ),
    );
    expect(tester.takeException(), isNull);
    final bar = tester.getRect(find.byType(KioskHeadline));
    expect(tester.getRect(find.text('1/2')).right, lessThan(bar.right));
    final title = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.textContaining('Zámek kuželny'),
        matching: find.byType(RichText),
      ),
    );
    expect(title.didExceedMaxLines, isTrue);
    expect(title.overflow, TextOverflow.ellipsis);
  });

  testWidgets('a fresh notice wears „NOVÉ“ between the icon and the title; '
      'an old one does not, nor a fresh one with the highlight off', (
    tester,
  ) async {
    await tester.pumpWidget(
      app([notice('2', 'Zámek', posted: yesterday), notice('1', 'Brigáda')]),
    );
    expect(find.text('NOVÉ'), findsOneWidget);
    final chip = tester.getCenter(find.byType(KioskNewChip)).dx;
    expect(
      chip,
      greaterThan(tester.getCenter(find.byIcon(Icons.campaign_outlined)).dx),
    );
    expect(chip, lessThan(tester.getTopLeft(find.text('Zámek')).dx));

    // The next one, of September: plain.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Brigáda'), findsOneWidget);
    expect(find.byType(KioskNewChip), findsNothing);

    // Shown longer, not highlighted: no chip on the fresh one either.
    await tester.pumpWidget(
      app([
        notice('2', 'Zámek', posted: yesterday),
      ], fresh: KioskNoticesFresh.longer),
    );
    await tester.pumpAndSettle();
    expect(find.text('Zámek'), findsOneWidget);
    expect(find.byType(KioskNewChip), findsNothing);
  });

  testWidgets('fresh notices shown longer: a fresh one stays twice the '
      'turn, an old one the turn', (tester) async {
    await tester.pumpWidget(
      app([
        notice('2', 'Zámek', posted: yesterday),
        notice('1', 'Brigáda'),
      ], fresh: KioskNoticesFresh.longer),
    );
    // One turn: the fresh one still shows.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Zámek'), findsOneWidget);
    expect(find.text('Brigáda'), findsNothing);
    // The second turn: the old one.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Brigáda'), findsOneWidget);
    expect(find.text('Zámek'), findsNothing);
    // The old one's single turn: the fresh one again.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Zámek'), findsOneWidget);
  });

  testWidgets('a newly posted notice shows at once, first, for a whole turn '
      'of its own', (tester) async {
    final up = [notice('2', 'Zámek'), notice('1', 'Brigáda')];
    await tester.pumpWidget(app(up));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Brigáda'), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);

    // Two seconds into Brigáda's turn a new notice goes up.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(
      app([notice('3', 'Turnaj', posted: yesterday), ...up]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Turnaj'), findsOneWidget);
    expect(find.text('1/3'), findsOneWidget);
    // Past the end of Brigáda's turn it still shows ...
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Turnaj'), findsOneWidget);
    // ... and after its own the next one comes.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('Zámek'), findsOneWidget);
    expect(find.text('2/3'), findsOneWidget);
  });

  testWidgets('when notices come down, the counter stays within them', (
    tester,
  ) async {
    final three = [
      notice('3', 'Turnaj'),
      notice('2', 'Zámek'),
      notice('1', 'Brigáda'),
    ];
    await tester.pumpWidget(app(three));
    for (var i = 0; i < 2; i++) {
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }
    expect(find.text('Brigáda'), findsOneWidget);
    expect(find.text('3/3'), findsOneWidget);

    // Brigáda is taken down: the last one left shows.
    await tester.pumpWidget(app(three.take(2).toList()));
    await tester.pumpAndSettle();
    expect(find.text('Zámek'), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);
  });
}
