import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/features/profile/changelog_data.dart';

/// The changelog is the single source of the Play "what's new", the GitHub
/// Release notes and the in-app Novinky (tool/whatsnew.dart) — so a version
/// bump without an entry must fail here, not on the Play upload.
void main() {
  test('the newest changelog entry matches the pubspec version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(r'^version:\s*(\d+\.\d+\.\d+)\+\d+', multiLine: true)
        .firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml has no version: x.y.z+n');
    expect(
      appChangelog.first.version,
      match!.group(1),
      reason: 'add a Release entry to changelog_data.dart for this version',
    );
  });

  test('changelog versions are unique, newest first, with non-empty notes',
      () {
    List<int> parts(String v) => v.split('.').map(int.parse).toList();
    int compare(String a, String b) {
      final pa = parts(a), pb = parts(b);
      for (var i = 0; i < 3; i++) {
        if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
      }
      return 0;
    }

    final versions = [for (final r in appChangelog) r.version];
    expect(versions.toSet().length, versions.length, reason: 'duplicate version');
    for (var i = 1; i < versions.length; i++) {
      expect(compare(versions[i - 1], versions[i]), greaterThan(0),
          reason: '${versions[i - 1]} must be newer than ${versions[i]}');
    }
    for (final r in appChangelog) {
      expect(r.changes, isNotEmpty, reason: '${r.version} has no notes');
      expect(r.date, isNotEmpty);
    }
  });
}
