import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/kiosk/kiosk_headline.dart';

/// The notice titles in the kiosk's status bar take turns with a cross-fade.
/// The next title fades in where it will stay and the last one fades out
/// where it was: when the fade is over, nothing jumps.
void main() {
  Message notice(String id, String title) => Message(
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
    createdAt: DateTime(2026, 9, 1),
    updatedAt: DateTime(2026, 9, 1),
  );

  Widget app(
    List<Message> notices, {
    double width = 900,
    void Function(Message)? onOpen,
  }) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: KioskHeadline(
            notices: notices,
            turn: const Duration(seconds: 5),
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
}
