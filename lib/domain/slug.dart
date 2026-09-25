/// Slugs an admin types: the public overview's address part (0043), what
/// comes after `#/prehled/`, and the kuželna's page on the ČKA results site
/// (0045/0047). Pure Dart, unit-tested.
library;

import 'collation.dart';

/// Mirrors the DB check `tenants_public_slug_format`: 3–40 characters,
/// lower-case letters without diacritics, digits, a hyphen only inside.
/// The admin screen has no client-side validator wired to this — the server
/// is the only enforcement — so this pattern's job today is keeping the unit
/// tests in sync with the DB check, not hinting a form.
final slugPattern = RegExp(r'^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$');

/// A slug suggested from the alley's name — diacritics folded, lower case,
/// every run of anything else one hyphen, at most 40 characters. '' when the
/// name leaves fewer than 3 characters (the admin then types their own).
String suggestSlug(String name) {
  var s = foldDiacritics(name)
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (s.length > 40) {
    s = s.substring(0, 40).replaceAll(RegExp(r'-+$'), '');
  }
  return s.length < 3 ? '' : s;
}

/// Mirrors set_federation_sync's check on the kuželna's slug (0045):
/// lower-case letters without diacritics and digits, a single hyphen only
/// between them.
final venueSlugPattern = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

/// The kuželna's slug out of what the admin pasted: its page's whole
/// address, with or without the host, or the slug alone. Trimmed and
/// lower-cased; a query, a fragment and trailing slashes are dropped. null
/// when what is left is no slug.
String? venueSlugFromInput(String input) {
  var s = input.trim().toLowerCase();
  final tail = s.indexOf(RegExp('[?#]'));
  if (tail >= 0) s = s.substring(0, tail);
  s = s.replaceAll(RegExp(r'/+$'), '');
  const page = 'detail-kuzelny/';
  final at = s.lastIndexOf(page);
  if (at >= 0) s = s.substring(at + page.length);
  return venueSlugPattern.hasMatch(s) ? s : null;
}

/// The kuželna field's inline error for [input], or null when it holds a
/// slug.
String? venueSlugInputError(String input) {
  if (input.trim().isEmpty) return 'Vlož adresu stránky kuželny.';
  if (venueSlugFromInput(input) == null) {
    return 'Tohle není adresa kuželny — zkopíruj adresu stránky, která '
        'obsahuje /detail-kuzelny/.';
  }
  return null;
}
