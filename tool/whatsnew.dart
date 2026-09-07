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
// Play caps "What's new" at 500 chars per language; a longer entry fails the
// release here rather than reaching testers cut off mid-sentence.
import 'dart:io';

import 'package:rezervator/features/profile/changelog_data.dart';

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

  final text = release.changes.map((c) => '• $c').join('\n');
  // Play caps this at 500 per language. This used to trim with an ellipsis
  // and carry on, which was survivable while the upload landed as a draft
  // someone reviewed by hand; now the release goes live on the internal
  // track straight away, so a sentence cut mid-word would reach testers
  // with nobody in between. Stop the release instead — shorten the entry,
  // move the tag, push again.
  if (text.length > 500) {
    stderr.writeln('What\'s-new text is ${text.length} chars, Play takes 500 '
        '— shorten the ${release.version} entry in changelog_data.dart.');
    exit(1);
  }

  if (outPath != null) {
    File(outPath).writeAsStringSync(text);
  } else {
    stdout.write(text);
  }
}
