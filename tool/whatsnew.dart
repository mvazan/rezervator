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
// Play caps "What's new" at 500 chars per language; we trim with an ellipsis
// if an entry ever runs long (it warns on stderr so it doesn't pass silently).
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

  final release = version == null
      ? appChangelog.first
      : appChangelog.firstWhere((r) => r.version == version,
          orElse: () => throw 'No changelog entry for $version');

  var text = release.changes.map((c) => '• $c').join('\n');
  if (text.length > 500) {
    stderr.writeln('warning: What\'s-new text is ${text.length} chars (>500); '
        'Play will reject it — shorten the ${release.version} entry.');
    text = '${text.substring(0, 497)}...';
  }

  if (outPath != null) {
    File(outPath).writeAsStringSync(text);
  } else {
    stdout.write(text);
  }
}
