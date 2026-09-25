import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/widgets/federation_card.dart';

/// The ČKA card on its own (Správa → Oddíly). Each (re)build of the sync
/// row's or the teams' provider takes the next of [rows] / [teams], the
/// last one repeating, so a test sees what the card fetches again.
class _Harness {
  _Harness({List<FederationSync>? rows, List<List<Team>>? teams})
      : rows = rows ?? const [FederationSync.none],
        teams = teams ?? const [<Team>[]];

  final List<FederationSync> rows;
  final List<List<Team>> teams;
  int rowBuilds = 0;
  int teamBuilds = 0;
  final saved = <(String, bool)>[];
  int discoveries = 0;
  int syncs = 0;

  /// Thrown by the next saves instead of saving.
  Object? saveError;

  static T _nth<T>(List<T> list, int i) =>
      list[i < list.length ? i : list.length - 1];

  Widget app() => ProviderScope(
        overrides: [
          federationSyncProvider
              .overrideWith((ref) => Stream.value(_nth(rows, rowBuilds++))),
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
                discoverTeams: () async => discoveries++,
                syncNow: () async => syncs++,
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

}
