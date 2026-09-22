/// The public overview's address part (0043): what an admin types after
/// `#/prehled/`. Pure Dart, unit-tested.
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
