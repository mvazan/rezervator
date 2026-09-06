import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/features/profile/changelog.dart';

/// The changelog is the single source of the Play "what's new", the GitHub
/// Release notes and the in-app Novinky (tool/whatsnew.dart) — so a version
/// bump without an entry must fail here, not on the Play upload.
void main() {
  final released = [
    for (final r in appChangelog)
      if (r.version != null) r,
  ];

  test('the newest RELEASED entry matches the pubspec version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(r'^version:\s*(\d+\.\d+\.\d+)\+\d+', multiLine: true)
        .firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml has no version: x.y.z+n');
    expect(
      released.first.version,
      match!.group(1),
      reason: 'add a Release entry to changelog_data.dart for this version',
    );
  });

  test('entries not yet in any release sit at the top — they are the newest',
      () {
    final versions = [for (final r in appChangelog) r.version];
    final firstReleased = versions.indexWhere((v) => v != null);
    expect(firstReleased, isNot(-1), reason: 'no released entry at all');
    expect(
      versions.skip(firstReleased).every((v) => v != null),
      isTrue,
      reason: 'a web-only entry (version null) may not sit below a release',
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

    final versions = [for (final r in released) r.version!];
    expect(versions.toSet().length, versions.length, reason: 'duplicate version');
    for (var i = 1; i < versions.length; i++) {
      expect(compare(versions[i - 1], versions[i]), greaterThan(0),
          reason: '${versions[i - 1]} must be newer than ${versions[i]}');
    }
    for (final r in appChangelog) {
      expect(r.changes, isNotEmpty, reason: '${r.date} has no notes');
      expect(r.date, isNotEmpty);
    }
  });

  group('what each platform shows', () {
    test('the app lists releases only — an installed build has nothing else',
        () {
      final shown = changelogFor(web: false);
      expect(shown.every((r) => r.version != null), isTrue);
      expect(shown.length, released.length);
      expect(changelogHeading(shown.first, web: false),
          startsWith('verze ${shown.first.version}'));
    });

    test('the web lists every batch by date, web-only ones marked', () {
      final shown = changelogFor(web: true);
      expect(shown.length, appChangelog.length);
      // Usually there is a web-only batch; right after a release that folds
      // in the whole backlog there is none yet — a valid state (PLAY.md).
      final webOnlyEntries = shown.where((r) => r.version == null);
      if (webOnlyEntries.isNotEmpty) {
        final webOnly = webOnlyEntries.first;
        expect(changelogHeading(webOnly, web: true),
            '${webOnly.date} · zatím jen na webu');
      }
      final releasedEntry = shown.firstWhere((r) => r.version != null);
      expect(changelogHeading(releasedEntry, web: true),
          '${releasedEntry.date} · verze ${releasedEntry.version}');
    });
  });

  group('the sheet', () {
    Future<void> open(WidgetTester tester, {required bool web}) async {
      // Tall enough that the sheet (60 % of the view) holds every batch —
      // the list is lazy, so an off-screen heading is simply not built.
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showChangelog(context, web: web),
              child: const Text('otevřít'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('otevřít'));
      await tester.pumpAndSettle();
    }

    // Usually there IS a batch no build carries yet — the web deploys on
    // every merge, releases only catch up now and then. Right after a
    // release that folds the whole backlog in (see PLAY.md), there is
    // none — a valid state, so these checks skip rather than crash.
    final pending = appChangelog.where((r) => r.version == null);
    final webOnly = pending.isEmpty ? null : pending.first;
    final newestRelease = appChangelog.firstWhere((r) => r.version != null);

    testWidgets('in the app: versions only, no web talk', (tester) async {
      await open(tester, web: false);

      expect(find.text('Co je nového'), findsOneWidget);
      expect(find.textContaining('Web se aktualizuje'), findsNothing);
      expect(find.text('verze ${newestRelease.version} · ${newestRelease.date}'),
          findsOneWidget);
      // A batch that no build carries must not be advertised in the app.
      if (webOnly != null) {
        expect(find.text('${webOnly.date} · zatím jen na webu'), findsNothing);
        expect(find.text('• ${webOnly.changes.first}'), findsNothing);
      }
    });

    testWidgets('on the web: dated batches, the newest not in any version yet',
        (tester) async {
      await open(tester, web: true);

      expect(find.textContaining('Web se aktualizuje průběžně'), findsOneWidget);
      expect(find.text('${newestRelease.date} · verze ${newestRelease.version}'),
          findsOneWidget);
      if (webOnly != null) {
        expect(find.text('${webOnly.date} · zatím jen na webu'), findsOneWidget);
        expect(find.text('• ${webOnly.changes.first}'), findsOneWidget);
      }
    });
  });
}
