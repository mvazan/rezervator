/// Text whose 🏠 is drawn from a bundled image, not from a font.
///
/// On the web an emoji is set in whichever fallback font the engine has
/// loaded when the line is laid out: a line built before the colour emoji
/// font arrives keeps a flat, text-coloured house, one built after gets the
/// colour one — so a day header and a list row scrolled in later showed two
/// different houses. The image (Noto Color Emoji's own house) is the same
/// everywhere and from the first frame. The text itself keeps the 🏠, so
/// screen readers and tests read it as before.
library;

import 'package:flutter/material.dart';

const _house = '🏠';
const _houseAsset = 'assets/images/emoji_house.png';

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
    if (!text.contains(_house)) {
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      );
    }
    final effective = DefaultTextStyle.of(context).style.merge(style);
    final size = (effective.fontSize ?? 14) * 1.15;
    final parts = text.split(_house);
    return Text.rich(
      TextSpan(
        children: [
          for (var i = 0; i < parts.length; i++) ...[
            if (i > 0)
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Image.asset(
                  _houseAsset,
                  width: size,
                  height: size,
                  excludeFromSemantics: true,
                ),
              ),
            if (parts[i].isNotEmpty) TextSpan(text: parts[i]),
          ],
        ],
      ),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
      semanticsLabel: text,
    );
  }
}
