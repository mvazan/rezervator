/// Text whose emoji are drawn from bundled images, not from a font.
///
/// On the web an emoji is set in whichever fallback font the engine has
/// loaded when the line is laid out: a line built before the colour emoji
/// font arrives keeps a flat, text-coloured glyph, one built after gets the
/// colour one — so a day header and a list row scrolled in later showed two
/// different houses. The images (Noto Color Emoji's own, Apache 2.0) are the
/// same everywhere and from the first frame. The text itself keeps its
/// emoji, so screen readers and tests read it as before.
library;

import 'package:flutter/material.dart';

/// Every emoji the app prints, by its image under assets/images/emoji/
/// (Noto's file names: emoji_u<code point>.png).
const _emojiAssets = {
  '🏠': 'assets/images/emoji/emoji_u1f3e0.png',
  '⛔': 'assets/images/emoji/emoji_u26d4.png',
  '🏆': 'assets/images/emoji/emoji_u1f3c6.png',
  '🔒': 'assets/images/emoji/emoji_u1f512.png',
  '👍': 'assets/images/emoji/emoji_u1f44d.png',
  '👎': 'assets/images/emoji/emoji_u1f44e.png',
  '💬': 'assets/images/emoji/emoji_u1f4ac.png',
  '✋': 'assets/images/emoji/emoji_u270b.png',
  '✨': 'assets/images/emoji/emoji_u2728.png',
  '➕': 'assets/images/emoji/emoji_u2795.png',
  '🏗': 'assets/images/emoji/emoji_u1f3d7.png',
  '🕰': 'assets/images/emoji/emoji_u1f570.png',
};

/// One of [_emojiAssets], with the emoji presentation selector (U+FE0F) that
/// may follow it.
final _emojiPattern = RegExp(
  '(${_emojiAssets.keys.join('|')})\u{FE0F}?',
);

/// Whether [text] holds an emoji [EmojiText] draws as an image.
bool hasDrawnEmoji(String text) => _emojiPattern.hasMatch(text);

/// [text] as spans: plain text, and each emoji as an image the height of the
/// line's text ([fontSize] × 1.15). For a [TextSpan] that mixes several
/// styles; a plain string is simpler as [EmojiText].
List<InlineSpan> emojiSpans(String text, {double? fontSize, TextStyle? style}) {
  final size = (fontSize ?? style?.fontSize ?? 14) * 1.15;
  final spans = <InlineSpan>[];
  var start = 0;
  for (final m in _emojiPattern.allMatches(text)) {
    if (m.start > start) {
      spans.add(TextSpan(text: text.substring(start, m.start), style: style));
    }
    spans.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Image.asset(
          _emojiAssets[m.group(1)]!,
          width: size,
          height: size,
          excludeFromSemantics: true,
        ),
      ),
    );
    start = m.end;
  }
  if (start < text.length) {
    spans.add(TextSpan(text: text.substring(start), style: style));
  }
  return spans;
}

class EmojiText extends StatelessWidget {
  const EmojiText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    if (!hasDrawnEmoji(text)) {
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      );
    }
    final effective = DefaultTextStyle.of(context).style.merge(style);
    return Text.rich(
      TextSpan(children: emojiSpans(text, fontSize: effective.fontSize)),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
      semanticsLabel: text,
    );
  }
}
