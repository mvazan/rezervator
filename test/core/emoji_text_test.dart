import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/widgets/emoji_text.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

/// The asset each drawn emoji's image comes from.
List<String> _assets(WidgetTester tester) => [
  for (final image in tester.widgetList<Image>(find.byType(Image)))
    (image.image as AssetImage).assetName,
];

void main() {
  // Every emoji the app prints (labels, messages, the season's end, sign-up).
  const drawn = {
    '🏠': 'emoji_u1f3e0',
    '⛔': 'emoji_u26d4',
    '🏆': 'emoji_u1f3c6',
    '🔒': 'emoji_u1f512',
    '👍': 'emoji_u1f44d',
    '👎': 'emoji_u1f44e',
    '💬': 'emoji_u1f4ac',
    '✋': 'emoji_u270b',
    '✨': 'emoji_u2728',
    '➕': 'emoji_u2795',
    '🏗': 'emoji_u1f3d7',
    '🕰': 'emoji_u1f570',
  };

  for (final MapEntry(key: emoji, value: file) in drawn.entries) {
    testWidgets('$emoji is drawn from $file.png, which is bundled', (
      tester,
    ) async {
      await tester.pumpWidget(_host(EmojiText('$emoji Veverky A')));
      expect(_assets(tester), ['assets/images/emoji/$file.png']);
      expect(File('assets/images/emoji/$file.png').existsSync(), isTrue);
    });
  }

  testWidgets('the emoji presentation selector after an emoji is dropped with '
      'it, not printed', (tester) async {
    await tester.pumpWidget(_host(const EmojiText('🏗️')));
    expect(_assets(tester), ['assets/images/emoji/emoji_u1f3d7.png']);
    final rich = tester.widget<Text>(find.byType(Text)).textSpan!;
    expect(rich.toPlainText().contains('\u{FE0F}'), isFalse);
  });

  testWidgets('several emoji in one line, text kept between them', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const EmojiText('2× 👍 · 1× 👎 · 1× 💬')));
    expect(_assets(tester), [
      'assets/images/emoji/emoji_u1f44d.png',
      'assets/images/emoji/emoji_u1f44e.png',
      'assets/images/emoji/emoji_u1f4ac.png',
    ]);
    expect(find.textContaining('2× ', findRichText: true), findsOneWidget);
  });

  testWidgets('text without a drawn emoji stays a plain Text', (tester) async {
    await tester.pumpWidget(_host(const EmojiText('Pronájem · 17:00–18:00')));
    expect(find.byType(Image), findsNothing);
    expect(find.text('Pronájem · 17:00–18:00'), findsOneWidget);
  });

  testWidgets('screen readers read the emoji as text', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(const EmojiText('⛔ Údržba')));
    expect(find.bySemanticsLabel('⛔ Údržba'), findsOneWidget);
    handle.dispose();
  });
}
