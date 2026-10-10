import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/widgets/emoji_text.dart';

/// An [EmojiText] showing exactly [text]. Its emoji are images, so
/// `find.text` (which reads the text spans) cannot see it.
Finder findEmojiText(String text) => find.byWidgetPredicate(
  (w) => w is EmojiText && w.text == text,
  description: 'EmojiText "$text"',
);

/// An [EmojiText] whose text contains [part].
Finder findEmojiTextContaining(String part) => find.byWidgetPredicate(
  (w) => w is EmojiText && w.text.contains(part),
  description: 'EmojiText containing "$part"',
);

/// A [type] widget holding an [EmojiText] of exactly [text] — the emoji
/// twin of `find.widgetWithText`.
Finder findWidgetWithEmojiText(Type type, String text) => find.ancestor(
  of: findEmojiText(text),
  matching: find.byType(type),
);
