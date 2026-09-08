// Emits a changelog entry as plain text, one bullet per line — used by CI to
// fill Google Play's "What's new" and the GitHub Release notes from the same
// source the app shows in-app (Můj profil → co je nového).
//
//   dart run tool/whatsnew.dart 1.0.1                 # print to stdout
//   dart run tool/whatsnew.dart 1.0.1 --out=path      # write straight to file
//   dart run tool/whatsnew.dart                       # latest entry, stdout
//
// Prefer --out in CI: `dart run` prints its own "Running build hooks…" line to
// stdout, which would leak into a `> redirect`. Writing the file from here
// keeps that noise out of the release notes.
//
// Play caps "What's new" at 500 chars per language; storeNotes condenses a
// longer entry down to size (see store_notes.dart).
import 'dart:io';

import 'package:rezervator/features/profile/changelog_data.dart';
import 'package:rezervator/features/profile/store_notes.dart';

void main(List<String> args) {
  String? version;
  String? outPath;
  for (final a in args) {
    if (a.startsWith('--out=')) {
      outPath = a.substring('--out='.length);
    } else {
      version ??= a;
    }
  }

  // Without an argument: the newest entry that a release carries. The top
  // of the changelog can be web-only batches (version null) — those are not
  // in any build, so they must never become a store text.
  final release = version == null
      ? appChangelog.firstWhere((r) => r.version != null,
          orElse: () => throw 'No released changelog entry')
      : appChangelog.firstWhere((r) => r.version == version,
          orElse: () => throw 'No changelog entry for $version');

  // Play takes 500 characters per language and refuses anything longer, so
  // storeNotes trims — whole sentences first, then whole bullets — instead
  // of letting a release fail on a long entry or, worse, reach testers with
  // a sentence cut mid-word. What the app shows in Novinky stays the full
  // text; only the store copy is condensed.
  final text = storeNotes(release.changes);

  if (outPath != null) {
    File(outPath).writeAsStringSync(text);
  } else {
    stdout.write(text);
  }
}
