import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/widgets/federation_card.dart';
import 'package:rezervator/features/admin/widgets/venue_slug_field.dart';

/// The ČKA card on its own (Správa → Oddíly). Each (re)build of the sync
/// row's or the teams' provider takes the next of [rows] / [teams], and
/// each look at the progress the next of [progress] — the last one
/// repeating — so a test sees what the card fetches again, and when.
/// [push] is the row's Realtime stream: a newer row without a refetch.
class _Harness {
  _Harness({
    List<FederationSync>? rows,
    List<List<Team>>? teams,
    List<FederationSyncProgress>? progress,
  })  : rows = rows ?? const [FederationSync.none],
        teams = teams ?? const [<Team>[]],
        progress = progress ?? const [FederationSyncProgress.idle];

  final List<FederationSync> rows;
  final List<List<Team>> teams;
  final List<FederationSyncProgress> progress;
  int rowBuilds = 0;
  int teamBuilds = 0;
  int looks = 0;
  final saved = <(String, bool)>[];
  int discoveries = 0;
  int syncs = 0;
  final _live = StreamController<FederationSync>.broadcast();

  /// Thrown by the next saves instead of saving.
  Object? saveError;

  /// Holds a discovery or sync request open until completed — the server
  /// answering it takes a moment.
  Completer<void>? hold;

  /// Delivers [row] as Realtime does: the card sees it without a refetch.
  void push(FederationSync row) => _live.add(row);

  static T _nth<T>(List<T> list, int i) =>
      list[i < list.length ? i : list.length - 1];

  Widget app() => ProviderScope(
        overrides: [
          federationSyncProvider.overrideWith((ref) async* {
            yield _nth(rows, rowBuilds++);
            yield* _live.stream;
          }),
          teamsProvider
              .overrideWith((ref) => Stream.value(_nth(teams, teamBuilds++))),
          clubsProvider.overrideWith((ref) => Stream.value(const <Club>[])),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FederationCard(
                saveFederation: (slug, enabled) async {
                  final error = saveError;
                  if (error != null) throw error;
                  saved.add((slug, enabled));
                },
                discoverTeams: () async {
                  discoveries++;
                  await hold?.future;
                },
                syncNow: () async {
                  syncs++;
                  await hold?.future;
                },
                syncProgress: () async => _nth(progress, looks++),
              ),
            ),
          ),
        ),
      );
}

/// Pumps without settling: a spinning progress line never settles.
Future<void> _pump(WidgetTester tester, _Harness h) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(h.app());
  await tester.pump();
  await tester.pump();
}

const _on = FederationSync(venueSlug: 'tj-sokol-brno-iv', enabled: true);

/// Synced before and switched off since: still the normal view.
final _off = FederationSync(
  venueSlug: 'tj-sokol-brno-iv',
  lastRunAt: DateTime.utc(2026, 9, 24, 1),
);

void main() {
  group('normal view', () {
    testWidgets('the kuželna is read-only behind a pencil; there is no Uložit',
        (tester) async {
      await _pump(tester, _Harness(rows: [_on]));

      expect(find.text('Kuželna na webu'), findsOneWidget);
      expect(find.text('detail-kuzelny/tj-sokol-brno-iv'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('Změnit kuželnu'), findsOneWidget);
      expect(find.text('Uložit'), findsNothing);
    });

    testWidgets(
        'the pencil saves the slug of a pasted page address, the switch kept',
        (tester) async {
      final h = _Harness(rows: [_on]);
      await _pump(tester, h);

      await tester.tap(find.byTooltip('Změnit kuželnu'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(find.descendant(of: dialog, matching: find.text('Změnit kuželnu')),
          findsOneWidget);
      expect(find.widgetWithText(TextField, 'tj-sokol-brno-iv'), findsOneWidget);

      await tester.enterText(find.byType(TextField),
          'https://vysledky.kuzelky.cz/detail-kuzelny/KS-Devitka-Brno/?tab=1');
      await tester.tap(find.descendant(of: dialog, matching: find.text('Uložit')));
      await tester.pumpAndSettle();

      expect(h.saved, [('ks-devitka-brno', true)]);
      expect(dialog, findsNothing);
    });

    testWidgets('the pencil refuses the address of another page, inline',
        (tester) async {
      final h = _Harness(rows: [_on]);
      await _pump(tester, h);

      await tester.tap(find.byTooltip('Změnit kuželnu'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField),
          'https://vysledky.kuzelky.cz/detail-klubu/ks-devitka-brno');
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Uložit')));
      await tester.pumpAndSettle();

      expect(h.saved, isEmpty);
      expect(
        find.text('Tohle není adresa kuželny — zkopíruj adresu stránky, která '
            'obsahuje /detail-kuzelny/.'),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsOneWidget);
    });

    testWidgets('Stahovat automaticky saves at once', (tester) async {
      final h = _Harness(rows: [_on]);
      await _pump(tester, h);

      await tester.tap(find.text('Stahovat automaticky'));
      await tester.pump();
      await tester.pump();

      expect(h.saved, [('tj-sokol-brno-iv', false)]);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isFalse);
    });

    testWidgets('a refused switch save flips back and says why',
        (tester) async {
      final h = _Harness(rows: [_on])..saveError = Exception('not_allowed');
      await _pump(tester, h);

      await tester.tap(find.text('Stahovat automaticky'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Na tohle nemáš oprávnění.'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue);
    });

    testWidgets(
        'Přenačíst týmy z webu asks for a discovery; Synchronizovat teď '
        'needs the switch on', (tester) async {
      final h = _Harness(rows: [_off]);
      await _pump(tester, h);

      final sync = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Synchronizovat teď'));
      expect(sync.onPressed, isNull);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Přenačíst týmy z webu'));
      await tester.pump();
      expect(h.discoveries, 1);
    });

    testWidgets('Synchronizovat teď asks for a sync', (tester) async {
      final h = _Harness(rows: [_on]);
      await _pump(tester, h);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Synchronizovat teď'));
      await tester.pump();
      expect(h.syncs, 1);
    });

    testWidgets('the last error shows', (tester) async {
      await _pump(
        tester,
        _Harness(rows: [
          const FederationSync(
              venueSlug: 'tj-sokol-brno-iv', enabled: true, lastError: 'boom'),
        ]),
      );

      expect(find.text('Chyba: boom'), findsOneWidget);
      expect(find.text('Poslední synchronizace: Zatím neproběhla'),
          findsOneWidget);
    });
  });

  group('progress (0047)', () {
    testWidgets(
        'a running sync spins with what is left; Poslední synchronizace '
        'stays below, muted', (tester) async {
      await _pump(
        tester,
        _Harness(rows: [
          _on
        ], progress: [
          const FederationSyncProgress(matches: 12, competitions: 2, venues: 1),
        ]),
      );

      expect(find.text('Synchronizuje se… zbývá 12 zápasů, 2 soutěže a 1 kuželna'),
          findsOneWidget);
      final spinner = find.byType(CircularProgressIndicator);
      expect(tester.getSize(spinner), const Size(14, 14));
      expect(tester.widget<CircularProgressIndicator>(spinner).strokeWidth, 2);
      final last = tester
          .widget<Text>(find.text('Poslední synchronizace: Zatím neproběhla'));
      final scheme =
          Theme.of(tester.element(find.byType(FederationCard))).colorScheme;
      expect(last.style?.color, scheme.onSurfaceVariant);
    });

    testWidgets('a running discovery reads Načítají se týmy z webu…',
        (tester) async {
      await _pump(
        tester,
        _Harness(rows: [
          _on
        ], progress: [
          const FederationSyncProgress(discover: 1, matches: 4),
        ]),
      );

      expect(find.text('Načítají se týmy z webu…'), findsOneWidget);
    });

    void expectControls(WidgetTester tester, {required bool enabled}) {
      final matcher = enabled ? isNotNull : isNull;
      expect(
          tester
              .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.edit_outlined))
              .onPressed,
          matcher,
          reason: 'Změnit kuželnu');
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
          matcher,
          reason: 'Stahovat automaticky');
      for (final label in ['Přenačíst týmy z webu', 'Synchronizovat teď']) {
        expect(
            tester
                .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, label))
                .onPressed,
            matcher,
            reason: label);
      }
    }

    testWidgets(
        'while a sync runs, the kuželna pencil, the switch and both buttons '
        'are off', (tester) async {
      await _pump(
        tester,
        _Harness(
            rows: [_on], progress: [const FederationSyncProgress(matches: 12)]),
      );

      expectControls(tester, enabled: false);
    });

    testWidgets('a running discovery turns them off too', (tester) async {
      await _pump(
        tester,
        _Harness(
            rows: [_on], progress: [const FederationSyncProgress(discover: 1)]),
      );

      expectControls(tester, enabled: false);
    });

    testWidgets('they come back once nothing is left to run', (tester) async {
      await _pump(
        tester,
        _Harness(rows: [
          _on
        ], progress: [
          const FederationSyncProgress(matches: 1),
          FederationSyncProgress.idle,
        ]),
      );
      expectControls(tester, enabled: false);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      await tester.pump();

      expectControls(tester, enabled: true);
    });

    for (final label in ['Přenačíst týmy z webu', 'Synchronizovat teď']) {
      testWidgets('$label turns them off while the server takes the request',
          (tester) async {
        final h = _Harness(rows: [_on])..hold = Completer<void>();
        await _pump(tester, h);

        await tester.tap(find.widgetWithText(OutlinedButton, label));
        await tester.pump();

        expectControls(tester, enabled: false);
        await tester.tap(find.widgetWithText(OutlinedButton, label),
            warnIfMissed: false);
        await tester.pump();
        expect(h.discoveries + h.syncs, 1, reason: 'no second request');

        h.hold!.complete();
        await tester.pump();
        await tester.pump();
      });
    }

    testWidgets(
        'Přenačíst týmy z webu turns them off at once, before any look sees '
        'the discovery run', (tester) async {
      final h = _Harness(rows: [_on]);
      await _pump(tester, h);
      expectControls(tester, enabled: true);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Přenačíst týmy z webu'));
      await tester.pump();
      await tester.pump();

      expect(h.discoveries, 1);
      expect(find.text('Načítají se týmy z webu…'), findsOneWidget);
      expectControls(tester, enabled: false);
    });

    testWidgets(
        'looks every 5 s while anything is pending, stops at 0 and fetches '
        'the row again', (tester) async {
      final h = _Harness(rows: [
        _on
      ], progress: [
        const FederationSyncProgress(matches: 2),
        const FederationSyncProgress(matches: 1),
        FederationSyncProgress.idle,
      ]);
      await _pump(tester, h);
      expect(h.looks, 1);
      expect(find.text('Synchronizuje se… zbývají 2 zápasy'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      expect(h.looks, 2);
      expect(find.text('Synchronizuje se… zbývá 1 zápas'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(h.looks, 3);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(h.rowBuilds, 2);

      await tester.pump(const Duration(seconds: 30));
      expect(h.looks, 3);
    });

    testWidgets('after Synchronizovat teď it looks for 60 s even at 0',
        (tester) async {
      final h = _Harness(rows: [_on]);
      await _pump(tester, h);
      expect(h.looks, 1);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Synchronizovat teď'));
      await tester.pump();
      expect(h.syncs, 1);
      expect(h.looks, 2);

      for (var i = 0; i < 11; i++) {
        await tester.pump(const Duration(seconds: 5));
      }
      expect(h.looks, 13);
      await tester.pump(const Duration(seconds: 30));
      expect(h.looks, 13);
    });

    testWidgets('no look while the app is in the background; one on return',
        (tester) async {
      final h = _Harness(
          rows: [_on], progress: [const FederationSyncProgress(matches: 3)]);
      await _pump(tester, h);
      expect(h.looks, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 30));
      expect(h.looks, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(h.looks, 2);
      await tester.pump(const Duration(seconds: 5));
      expect(h.looks, 3);
    });

    testWidgets('leaves no timer running once disposed', (tester) async {
      final h = _Harness(
          rows: [_on], progress: [const FederationSyncProgress(matches: 3)]);
      await _pump(tester, h);
      expect(h.looks, 1);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
      // testWidgets itself fails a test that ends with a timer pending.
      expect(h.looks, 1);
    });

    testWidgets(
        'Přenačíst týmy z webu reads Načítají se týmy z webu… until its '
        'report is in', (tester) async {
      final h = _Harness(
        rows: [
          FederationSync(
            venueSlug: 'tj-sokol-brno-iv',
            enabled: true,
            discover: FederationDiscoverReport(
                teams: 4, at: DateTime.utc(2026, 9, 24, 8)),
          ),
          FederationSync(
            venueSlug: 'tj-sokol-brno-iv',
            enabled: true,
            discover: FederationDiscoverReport(
                teams: 5, at: DateTime.utc(2026, 9, 25, 8)),
          ),
        ],
        progress: [
          FederationSyncProgress.idle,
          const FederationSyncProgress(discover: 1),
          FederationSyncProgress.idle,
        ],
      );
      await _pump(tester, h);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Přenačíst týmy z webu'));
      await tester.pump();
      expect(h.discoveries, 1);
      expect(find.text('Načítají se týmy z webu…'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      await tester.pump();
      expect(find.text('Načítají se týmy z webu…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets(
        'a failed discovery ends Načítají se týmy z webu… once its error is '
        'in the row, though its job still counts while it waits to retry',
        (tester) async {
      final h = _Harness(rows: [
        _on
      ], progress: [
        FederationSyncProgress.idle,
        const FederationSyncProgress(discover: 1),
      ]);
      await _pump(tester, h);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Přenačíst týmy z webu'));
      await tester.pump();
      expect(find.text('Načítají se týmy z webu…'), findsOneWidget);

      // A well-formed slug of no kuželna: HTTP 404. jobOutcome re-arms the
      // job at +1, +2, +4 and +8 min, and every look still counts it.
      const error =
          'federation_discover: GET /detail-kuzelny/tj-sokol-brno-iv: HTTP 404';
      h.push(FederationSync(
        venueSlug: 'tj-sokol-brno-iv',
        enabled: true,
        lastError: error,
        discover: FederationDiscoverReport(
            error: error, at: DateTime.utc(2026, 9, 25, 8)),
      ));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));

      expect(h.looks, 3);
      expect(find.text('Načítají se týmy z webu…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // The discovery's own line says it; „Chyba:“ would repeat it.
      expect(find.text('Poslední načtení týmů se nepovedlo: $error'),
          findsOneWidget);
      expect(find.text('Chyba: $error'), findsNothing);
    });

    testWidgets(
        'after a failed discovery the pencil\'s another kuželna reads no '
        'Načítají se týmy z webu…, though the old retrying job still counts',
        (tester) async {
      const error =
          'federation_discover: GET /detail-kuzelny/tj-sokol-brno-iv: HTTP 404';
      final h = _Harness(
        rows: [
          FederationSync(
            venueSlug: 'tj-sokol-brno-iv',
            enabled: true,
            lastError: error,
            discover: FederationDiscoverReport(
                error: error, at: DateTime.utc(2026, 9, 25, 8)),
          ),
        ],
        // The failed job backs off to retry and counts in every look the
        // card makes before the move reaches it (decision 7).
        progress: [const FederationSyncProgress(discover: 1)],
      );
      await _pump(tester, h);
      expect(find.text('Načítají se týmy z webu…'), findsNothing);

      await tester.tap(find.byTooltip('Změnit kuželnu'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField),
          'https://vysledky.kuzelky.cz/detail-kuzelny/ks-devitka-brno');
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Uložit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(h.saved, [('ks-devitka-brno', true)]);

      // The save's echo: set_federation_sync dropped the failed report and
      // its error.
      h.push(const FederationSync(venueSlug: 'ks-devitka-brno', enabled: true));
      await tester.pump();

      expect(find.text('detail-kuzelny/ks-devitka-brno'), findsOneWidget);
      expect(find.text('Načítají se týmy z webu…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('last discovery (0047 teams_created)', () {
    // Local time, so the label reads the same in any time zone.
    final at = DateTime(2026, 9, 25, 10, 5);
    const when = 'pá 25.9. 10:05';
    FederationSync withReport(FederationDiscoverReport report,
            {String? lastError}) =>
        FederationSync(
          venueSlug: 'tj-sokol-brno-iv',
          enabled: true,
          lastError: lastError,
          discover: report,
        );

    testWidgets('nothing new reads žádná změna, below the buttons',
        (tester) async {
      await _pump(
        tester,
        _Harness(rows: [
          withReport(FederationDiscoverReport(
              teams: 4,
              competitions: 2,
              clubsLinked: const ['Sokol Brno IV'],
              at: at)),
        ]),
      );

      final line = find.text('Poslední načtení týmů: $when · žádná změna');
      expect(line, findsOneWidget);
      expect(
          tester.getTopLeft(line).dy,
          greaterThan(tester
              .getBottomLeft(
                  find.widgetWithText(OutlinedButton, 'Přenačíst týmy z webu'))
              .dy));
    });

    testWidgets('one new team is named', (tester) async {
      await _pump(
        tester,
        _Harness(rows: [
          withReport(FederationDiscoverReport(
              teams: 5,
              created: 1,
              teamsCreated: const ['TJ Sokol Brno IV C'],
              at: at)),
        ]),
      );

      expect(
          find.text('Poslední načtení týmů: $when · nový tým: TJ Sokol Brno IV C'),
          findsOneWidget);
    });

    testWidgets('several new teams and a new oddíl, each with its plural',
        (tester) async {
      await _pump(
        tester,
        _Harness(rows: [
          withReport(FederationDiscoverReport(
              teams: 5,
              created: 2,
              teamsCreated: const ['TJ Sokol Husovice E', 'KS Devítka Brno B'],
              clubsCreated: const ['TJ Sokol Husovice'],
              at: at)),
        ]),
      );

      expect(
        find.text('Poslední načtení týmů: $when · '
            'nové týmy: KS Devítka Brno B, TJ Sokol Husovice E · '
            'nový oddíl: TJ Sokol Husovice'),
        findsOneWidget,
      );
    });

    testWidgets(
        'a failed one says so in the error colour, and „Chyba:“ does not '
        'repeat it', (tester) async {
      const error =
          'federation_discover: GET /detail-kuzelny/tj-sokol-brno-iv: HTTP 404';
      await _pump(
        tester,
        _Harness(rows: [
          withReport(FederationDiscoverReport(error: error, at: at),
              lastError: error),
        ]),
      );

      final line = find.text('Poslední načtení týmů se nepovedlo: $error');
      expect(line, findsOneWidget);
      final scheme =
          Theme.of(tester.element(find.byType(FederationCard))).colorScheme;
      expect(tester.widget<Text>(line).style?.color, scheme.error);
      expect(find.text('Chyba: $error'), findsNothing);
    });

    testWidgets('another error than the discovery\'s still reads Chyba:',
        (tester) async {
      const error = 'federation_discover: HTTP 404';
      await _pump(
        tester,
        _Harness(rows: [
          withReport(FederationDiscoverReport(error: error, at: at),
              lastError: 'federation_competition: HTTP 500'),
        ]),
      );

      expect(find.text('Poslední načtení týmů se nepovedlo: $error'),
          findsOneWidget);
      expect(find.text('Chyba: federation_competition: HTTP 500'),
          findsOneWidget);
    });

    testWidgets('hidden while a discovery runs: the loader shows then',
        (tester) async {
      await _pump(
        tester,
        _Harness(rows: [
          withReport(FederationDiscoverReport(teams: 4, at: at)),
        ], progress: [
          const FederationSyncProgress(discover: 1),
        ]),
      );

      expect(find.text('Načítají se týmy z webu…'), findsOneWidget);
      expect(find.textContaining('Poslední načtení týmů'), findsNothing);
    });

    testWidgets(
        'Přenačíst týmy z webu after a failed one: its error gives way to the '
        'loader too', (tester) async {
      const error = 'federation_discover: HTTP 404';
      final h = _Harness(rows: [
        withReport(FederationDiscoverReport(error: error, at: at),
            lastError: error),
      ]);
      await _pump(tester, h);
      expect(find.text('Poslední načtení týmů se nepovedlo: $error'),
          findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Přenačíst týmy z webu'));
      await tester.pump();

      expect(find.text('Načítají se týmy z webu…'), findsOneWidget);
      expect(find.textContaining('Poslední načtení týmů'), findsNothing);
      expect(find.textContaining('Chyba:'), findsNothing);
    });

    testWidgets('absent before any discovery', (tester) async {
      await _pump(tester, _Harness(rows: [_on]));

      expect(find.textContaining('Poslední načtení týmů'), findsNothing);
    });

    testWidgets(
        'after Přenačíst týmy z webu the loader gives way to the new result',
        (tester) async {
      final h = _Harness(
        rows: [
          withReport(FederationDiscoverReport(
              teams: 4, at: DateTime(2026, 9, 24, 9))),
          withReport(FederationDiscoverReport(
              teams: 5,
              created: 1,
              teamsCreated: const ['KS Devítka Brno B'],
              at: at)),
        ],
        progress: [
          FederationSyncProgress.idle,
          const FederationSyncProgress(discover: 1),
          FederationSyncProgress.idle,
        ],
      );
      await _pump(tester, h);
      expect(find.text('Poslední načtení týmů: čt 24.9. 9:00 · žádná změna'),
          findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Přenačíst týmy z webu'));
      await tester.pump();
      expect(find.text('Načítají se týmy z webu…'), findsOneWidget);
      expect(find.textContaining('Poslední načtení týmů'), findsNothing);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      await tester.pump();
      expect(find.text('Načítají se týmy z webu…'), findsNothing);
      expect(
          find.text('Poslední načtení týmů: $when · nový tým: KS Devítka Brno B'),
          findsOneWidget);
    });
  });

  group('setup wizard (0047)', () {
    const slugOnly = FederationSync(venueSlug: 'tj-sokol-brno-iv');
    const team = Team(
      id: 't1',
      name: 'TJ Sokol Brno IV A',
      clubId: 'c1',
      competitionName: 'Jihomoravská divize',
    );
    // This kuželna's teams are loaded: a successful discovery report.
    final discovered = FederationSync(
      venueSlug: 'tj-sokol-brno-iv',
      discover: FederationDiscoverReport(
        teams: 1,
        competitions: 1,
        created: 1,
        clubsLinked: const ['Sokol Brno IV'],
        at: DateTime.utc(2026, 9, 25, 8),
      ),
    );
    const notFound =
        'federation_discover: GET /detail-kuzelny/tj-sokol-brno-iv: HTTP 404';

    testWidgets('a new alley starts on step 1, the kuželna', (tester) async {
      await _pump(tester, _Harness());

      expect(find.text('Kuželna na webu ČKA'), findsOneWidget);
      expect(find.text(venueSlugHelp), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Pokračovat'), findsOneWidget);
      expect(find.text('Stahovat automaticky'), findsNothing);
    });

    testWidgets('a saved kuželna without teams opens step 2', (tester) async {
      await _pump(tester, _Harness(rows: [slugOnly]));

      expect(find.text('Oddíly a týmy'), findsOneWidget);
      expect(
        find.text('Načteme oddíly, které na kuželně hrají, a jejich týmy. '
            'Chybějící oddíly založíme.'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Načíst oddíly a týmy'),
          findsOneWidget);
    });

    testWidgets('a saved kuželna with its discovered teams opens step 3',
        (tester) async {
      await _pump(tester, _Harness(rows: [discovered], teams: [[team]]));

      expect(find.text('Zapnout stahování'), findsOneWidget);
      expect(
        find.text('Stáhnou se všechny zápasy a výsledky těchto týmů. Zápasy '
            'z rozpisu se spárují a zůstanou. První stažení trvá asi půl '
            'hodiny, pak se vše aktualizuje samo.'),
        findsOneWidget,
      );
    });

    testWidgets(
        'teams without a discovery of this kuželna open step 2 — a moved '
        'kuželna drops the old report', (tester) async {
      await _pump(tester, _Harness(rows: [slugOnly], teams: [[team]]));

      expect(find.text('Oddíly a týmy'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Načíst oddíly a týmy'),
          findsOneWidget);
      expect(find.text('Zapnout stahování'), findsNothing);
    });

    testWidgets(
        'step 1 saves the slug of a pasted address, the sync still off, '
        'and moves on', (tester) async {
      final h = _Harness();
      await _pump(tester, h);

      await tester.enterText(find.byType(TextField),
          ' https://vysledky.kuzelky.cz/detail-kuzelny/TJ-Sokol-Brno-IV/?tab=info#mapa ');
      await tester.tap(find.widgetWithText(FilledButton, 'Pokračovat'));
      await tester.pump();

      expect(h.saved, [('tj-sokol-brno-iv', false)]);
      expect(find.text('Oddíly a týmy'), findsOneWidget);
    });

    testWidgets('step 1 refuses the address of another page, inline',
        (tester) async {
      final h = _Harness();
      await _pump(tester, h);

      await tester.enterText(find.byType(TextField),
          'https://vysledky.kuzelky.cz/detail-klubu/ks-devitka-brno');
      await tester.tap(find.widgetWithText(FilledButton, 'Pokračovat'));
      await tester.pump();

      expect(h.saved, isEmpty);
      expect(
        find.text('Tohle není adresa kuželny — zkopíruj adresu stránky, která '
            'obsahuje /detail-kuzelny/.'),
        findsOneWidget,
      );
      expect(find.text('Kuželna na webu ČKA'), findsOneWidget);
    });

    testWidgets(
        'step 2 spins while the discovery runs, then sums up what it found',
        (tester) async {
      final report = FederationDiscoverReport(
        teams: 5,
        competitions: 2,
        created: 5,
        clubsLinked: const ['Sokol Brno IV'],
        clubsCreated: const ['TJ Sokol Husovice', 'KS Devítka Brno'],
        at: DateTime.utc(2026, 9, 25, 8),
      );
      final h = _Harness(
        rows: [
          slugOnly,
          FederationSync(venueSlug: 'tj-sokol-brno-iv', discover: report),
        ],
        teams: [const [], const [team]],
        progress: [
          FederationSyncProgress.idle,
          const FederationSyncProgress(discover: 1),
          FederationSyncProgress.idle,
        ],
      );
      await _pump(tester, h);

      await tester.tap(find.widgetWithText(FilledButton, 'Načíst oddíly a týmy'));
      await tester.pump();
      expect(h.discoveries, 1);
      expect(find.text('Načítají se oddíly a týmy z webu…'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Načíst oddíly a týmy'),
          findsNothing);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      await tester.pump();
      expect(find.text('Načítají se oddíly a týmy z webu…'), findsNothing);
      expect(find.text('3 oddíly (2 nové: KS Devítka Brno, TJ Sokol Husovice)'),
          findsOneWidget);
      expect(find.text('5 týmů ve 2 soutěžích'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Načíst znovu'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Pokračovat'));
      await tester.pump();
      expect(find.text('Zapnout stahování'), findsOneWidget);
    });

    testWidgets(
        'reopened while a failed discovery waits to retry, step 2 says why '
        'and offers Načíst znovu', (tester) async {
      const error =
          'federation_discover: na stránce kuželny nejsou žádné kluby';
      final h = _Harness(
        rows: [
          FederationSync(
            venueSlug: 'tj-sokol-brno-iv',
            discover: FederationDiscoverReport(
              error: error,
              at: DateTime.utc(2026, 9, 25, 8),
            ),
          ),
        ],
        // The alley has teams already (made by hand or imported): Pokračovat
        // stays off for the failed report, not for an empty team list.
        teams: [[team]],
        // The re-armed job still counts (plan decision 7).
        progress: [const FederationSyncProgress(discover: 1)],
      );
      await _pump(tester, h);

      expect(find.text('Načítají se oddíly a týmy z webu…'), findsNothing);
      expect(find.text('Načtení se nepovedlo: $error'), findsOneWidget);
      final next = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Pokračovat'));
      expect(next.onPressed, isNull);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Načíst znovu'));
      await tester.pump();
      expect(h.discoveries, 1);
      // A new request waits for its own report again.
      expect(find.text('Načítají se oddíly a týmy z webu…'), findsOneWidget);
    });

    testWidgets(
        'a discovery that found no team keeps step 2 and its Pokračovat off, '
        'though the alley has other teams', (tester) async {
      await _pump(
        tester,
        _Harness(
          rows: [
            FederationSync(
              venueSlug: 'tj-sokol-brno-iv',
              discover: FederationDiscoverReport(
                clubsLinked: const ['Sokol Brno IV'],
                at: DateTime.utc(2026, 9, 25, 8),
              ),
            ),
          ],
          teams: [[team]],
        ),
      );

      expect(find.text('Oddíly a týmy'), findsOneWidget);
      expect(
        find.text('Na kuželně se nenašel žádný tým. Zkontroluj adresu kuželny.'),
        findsOneWidget,
      );
      final next = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Pokračovat'));
      expect(next.onPressed, isNull);
      expect(find.text('Zapnout stahování'), findsNothing);
    });

    testWidgets(
        'another kuželna whose discovery fails keeps Pokračovat off, though '
        'the old one\'s teams stay', (tester) async {
      const typo = 'ks-devitka-brn';
      const typoNotFound =
          'federation_discover: GET /detail-kuzelny/$typo: HTTP 404';
      final h = _Harness(
        // The refetch after the discovery request reads the moved row.
        rows: [discovered, const FederationSync(venueSlug: typo)],
        teams: [[team]],
      );
      await _pump(tester, h);

      await tester.tap(find.widgetWithText(TextButton, 'Zpět'));
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Zpět'));
      await tester.pump();
      await tester.enterText(find.byType(TextField),
          'https://vysledky.kuzelky.cz/detail-kuzelny/$typo');
      await tester.tap(find.widgetWithText(FilledButton, 'Pokračovat'));
      await tester.pump();
      expect(h.saved, [(typo, false)]);

      // The save's echo: set_federation_sync dropped the old report.
      h.push(const FederationSync(venueSlug: typo));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Načíst oddíly a týmy'));
      await tester.pump();
      expect(h.discoveries, 1);

      h.push(FederationSync(
        venueSlug: typo,
        discover: FederationDiscoverReport(
          error: typoNotFound,
          at: DateTime.utc(2026, 9, 25, 9),
        ),
      ));
      await tester.pump();
      await tester.pump();

      expect(find.text('Načtení se nepovedlo: $typoNotFound'), findsOneWidget);
      final next = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Pokračovat'));
      expect(next.onPressed, isNull);
      expect(find.text('Zapnout stahování'), findsNothing);
    });

    testWidgets(
        'a discovery that fails ends the loader as soon as its error is in '
        'the row, though its job still counts while it waits to retry',
        (tester) async {
      final h = _Harness(
        rows: [slugOnly],
        progress: [
          FederationSyncProgress.idle,
          const FederationSyncProgress(discover: 1),
        ],
      );
      await _pump(tester, h);

      await tester.tap(find.widgetWithText(FilledButton, 'Načíst oddíly a týmy'));
      await tester.pump();
      expect(find.text('Načítají se oddíly a týmy z webu…'), findsOneWidget);

      // A well-formed slug of no kuželna: HTTP 404. jobOutcome re-arms the
      // job at +1, +2, +4 and +8 min, and every look still counts it.
      h.push(FederationSync(
        venueSlug: 'tj-sokol-brno-iv',
        discover: FederationDiscoverReport(
          error: notFound,
          at: DateTime.utc(2026, 9, 25, 8),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));

      expect(h.looks, 3);
      expect(find.text('Načítají se oddíly a týmy z webu…'), findsNothing);
      expect(find.text('Načtení se nepovedlo: $notFound'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Načíst znovu'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Zpět'), findsOneWidget);
    });

    testWidgets(
        'after a failed discovery another kuželna offers its own discovery: '
        'the move dropped the old one\'s retrying job, and Zpět never goes',
        (tester) async {
      const typo = 'tj-sokol-brno-4';
      const typoNotFound =
          'federation_discover: GET /detail-kuzelny/$typo: HTTP 404';
      final h = _Harness(
        rows: [
          FederationSync(
            venueSlug: typo,
            discover: FederationDiscoverReport(
              error: typoNotFound,
              at: DateTime.utc(2026, 9, 25, 8),
            ),
          ),
          slugOnly,
        ],
        progress: [
          // The failed job backs off to retry and still counts (decision 7).
          const FederationSyncProgress(discover: 1),
          // The next look comes after the move: set_federation_sync deleted
          // the old kuželna's job with its report (0047).
          FederationSyncProgress.idle,
        ],
      );
      await _pump(tester, h);
      expect(find.text('Načtení se nepovedlo: $typoNotFound'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Zpět'));
      await tester.pump();
      await tester.enterText(find.byType(TextField),
          'https://vysledky.kuzelky.cz/detail-kuzelny/tj-sokol-brno-iv');
      await tester.tap(find.widgetWithText(FilledButton, 'Pokračovat'));
      await tester.pump();
      expect(h.saved, [('tj-sokol-brno-iv', false)]);

      // The save's echo, without the report, before the card looks again:
      // whatever it counted last, step 2 keeps a way back.
      h.push(slugOnly);
      await tester.pump();
      expect(find.text('Oddíly a týmy'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Zpět'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      await tester.pump();
      expect(find.text('Načítají se oddíly a týmy z webu…'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Načíst oddíly a týmy'),
          findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Zpět'), findsOneWidget);
      expect(h.discoveries, 0);
    });

    testWidgets(
        'after a failed discovery, another kuželna\'s step 2 offers its own '
        'discovery at once, though the old retrying job still counts',
        (tester) async {
      const typo = 'tj-sokol-brno-4';
      const typoNotFound =
          'federation_discover: GET /detail-kuzelny/$typo: HTTP 404';
      final h = _Harness(
        rows: [
          FederationSync(
            venueSlug: typo,
            discover: FederationDiscoverReport(
              error: typoNotFound,
              at: DateTime.utc(2026, 9, 25, 8),
            ),
          ),
        ],
        // The failed job backs off to retry and counts in every look the
        // card makes before the move reaches it (decision 7).
        progress: [const FederationSyncProgress(discover: 1)],
      );
      await _pump(tester, h);
      expect(find.text('Načtení se nepovedlo: $typoNotFound'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Zpět'));
      await tester.pump();
      await tester.enterText(find.byType(TextField),
          'https://vysledky.kuzelky.cz/detail-kuzelny/tj-sokol-brno-iv');
      await tester.tap(find.widgetWithText(FilledButton, 'Pokračovat'));
      await tester.pump();
      expect(h.saved, [('tj-sokol-brno-iv', false)]);

      // The save's echo: set_federation_sync dropped the failed report.
      h.push(slugOnly);
      await tester.pump();

      expect(find.text('Oddíly a týmy'), findsOneWidget);
      expect(find.text('Načítají se oddíly a týmy z webu…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Načíst oddíly a týmy'),
          findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Zpět'), findsOneWidget);
      expect(h.discoveries, 0);

      // Asking for it spins again: a new request waits for its own report.
      await tester.tap(find.widgetWithText(FilledButton, 'Načíst oddíly a týmy'));
      await tester.pump();
      expect(h.discoveries, 1);
      expect(find.text('Načítají se oddíly a týmy z webu…'), findsOneWidget);
    });

    testWidgets('Zpět on step 2 goes back to the kuželna, its slug filled in',
        (tester) async {
      await _pump(tester, _Harness(rows: [slugOnly]));

      await tester.tap(find.widgetWithText(TextButton, 'Zpět'));
      await tester.pump();

      expect(find.text('Kuželna na webu ČKA'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'tj-sokol-brno-iv'), findsOneWidget);
    });

    testWidgets(
        'another kuželna saved after Zpět waits for its own discovery — the '
        'old one\'s summary and teams do not carry over', (tester) async {
      final h = _Harness(rows: [discovered], teams: [[team]]);
      await _pump(tester, h);
      expect(find.text('Zapnout stahování'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Zpět'));
      await tester.pump();
      expect(find.text('1 oddíl'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Zpět'));
      await tester.pump();
      await tester.enterText(find.byType(TextField),
          'https://vysledky.kuzelky.cz/detail-kuzelny/ks-devitka-brno');
      await tester.tap(find.widgetWithText(FilledButton, 'Pokračovat'));
      await tester.pump();

      expect(h.saved, [('ks-devitka-brno', false)]);
      // The row still holds the old kuželna's report until its echo.
      expect(find.text('Oddíly a týmy'), findsOneWidget);
      expect(find.text('1 oddíl'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Načíst oddíly a týmy'),
          findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Pokračovat'), findsNothing);
    });

    testWidgets(
        'step 3 switches the sync on, asks for the first run and leaves '
        'the wizard', (tester) async {
      final h = _Harness(rows: [discovered], teams: [[team]]);
      await _pump(tester, h);

      await tester
          .tap(find.widgetWithText(FilledButton, 'Zapnout a stáhnout zápasy'));
      await tester.pump();

      expect(h.saved, [('tj-sokol-brno-iv', true)]);
      expect(h.syncs, 1);
      expect(find.text('Zapnout stahování'), findsNothing);
      final toggle = tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, 'Stahovat automaticky'));
      expect(toggle.value, isTrue);
    });

    testWidgets('a sync that ever ran shows the normal view, even switched off',
        (tester) async {
      await _pump(tester, _Harness(rows: [_off]));

      expect(find.text('Kuželna na webu ČKA'), findsNothing);
      expect(find.text('Stahovat automaticky'), findsOneWidget);
    });
  });
}
