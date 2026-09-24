/// The "What's new" text for the app stores, built from a changelog entry.
///
/// Pure Dart (no Flutter import) so `tool/whatsnew.dart` can run it without a
/// Flutter runtime, the same reason changelog_data.dart is.
///
/// Play caps this at 500 characters per language and simply refuses anything
/// longer, so the text has to fit — and it has to fit BY ITSELF, because the
/// release goes straight to the internal testers with nobody in between to
/// notice a sentence cut mid-word. Hence [storeNotes]: it shortens in steps
/// that keep whole sentences, and only mangles a word in the case that cannot
/// be saved any other way.
library;

import 'changelog_data.dart';

/// The store text of [release]: its hand-written [Release.store] summary
/// when it has one, otherwise [storeNotes] of the full changes. A summary is
/// never shortened — it goes to Play exactly as reviewed, so one over
/// [limit] is an error, not something to trim.
String storeText(Release release, {int limit = 500}) {
  final store = release.store;
  if (store == null) return storeNotes(release.changes, limit: limit);
  final text = _bulleted(store);
  if (text.length > limit) {
    throw StateError('store summary of ${release.version ?? release.date} '
        'is ${text.length} characters, over the $limit limit');
  }
  return text;
}

String _bulleted(Iterable<String> lines) =>
    lines.map((c) => '• $c').join('\n');

/// [changes] as a bulleted store text of at most [limit] characters.
///
/// Whole text first; if it does not fit, each bullet drops to its first
/// sentence; if that still does not fit, bullets fall off the end (a changelog
/// entry is written most-important-first, so the tail is what a reader can
/// most afford to lose); and if even the first bullet is too long on its own,
/// it is cut at a word boundary with an ellipsis.
String storeNotes(List<String> changes, {int limit = 500}) {
  final full = _bulleted(changes);
  if (full.length <= limit) return full;

  final short = changes.map(firstSentence).toList();
  if (_bulleted(short).length <= limit) return _bulleted(short);

  for (var take = short.length - 1; take >= 1; take--) {
    final text = _bulleted(short.take(take));
    if (text.length <= limit) return text;
  }

  return _cutAtWord(_bulleted([short.first]), limit);
}

/// The first sentence of [text] — up to and including the first `.`, `!` or
/// `?` that a capital letter follows across a space. Czech is full of periods
/// that end nothing: „1.2.2", „15. 9.", „130 %.". Asking what comes AFTER the
/// space settles all of them, because a new sentence starts with a capital
/// and a date's next word does not. Erring towards "not a break" only keeps
/// more text, which the caller then shortens another way.
String firstSentence(String text) {
  for (var i = 0; i < text.length - 2; i++) {
    if (!'.!?'.contains(text[i]) || text[i + 1] != ' ') continue;
    if (_isCapital(text[i + 2])) return text.substring(0, i + 1);
  }
  return text;
}

/// True for a letter that has a distinct lower-case form and already is the
/// upper-case one — Czech letters included, digits and „ excluded.
bool _isCapital(String c) => c != c.toLowerCase() && c == c.toUpperCase();

/// [text] cut to at most [limit] characters, on a word boundary, ending in an
/// ellipsis. The last resort: one bullet longer than the whole budget.
String _cutAtWord(String text, int limit) {
  if (text.length <= limit) return text;
  var cut = text.substring(0, limit - 1);
  final space = cut.lastIndexOf(' ');
  if (space > 0) cut = cut.substring(0, space);
  return '$cut…';
}
