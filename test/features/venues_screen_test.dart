import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart' show dayLabel;
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/venue_detail_screen.dart';
import 'package:rezervator/features/clubhouse/venues_screen.dart';

// FilledButton.tonalIcon returns a `_FilledButtonWithIcon` subtype, so
// find.byType(FilledButton) (an exact-type match) never matches it — this
// finds the FilledButton ancestor (any subtype) of a button's own label.
Finder _filledButtonWithText(String text) => find.ancestor(
  of: find.text(text),
  matching: find.byWidgetPredicate((w) => w is FilledButton),
);

void main() {
  final brnoIv = Venue.fromJson(const {
    'id': 'v1',
    'slug': 'tj-sokol-brno-iv',
    'name': 'TJ Sokol Brno IV',
    'address': 'Štolcova 551/8, 61800 Brno',
    'phone': '736435492',
    'email': 'kuzelkybrnoiv@email.cz',
    'lat': 49.1891783,
    'lng': 16.6354503,
    'sections': [
      {
        'title': 'Technické informace',
        'items': [
          {'label': 'Dráhy', 'value': '4'},
          {'label': 'Kuželky', 'value': 'Syndur TOP'},
          {'label': 'Stavěč kuželek', 'value': 'Pro-Tec K800'},
        ],
      },
    ],
    'clubs': [
      'TJ Sokol Brno IV',
      'TJ Sokol Husovice',
      'KS Devítka Brno',
      'SKK Veverky Brno',
    ],
    'fetched_at': '2026-09-20T10:00:00+00:00',
  });

  final husovice = Venue.fromJson(const {
    'id': 'v2',
    'slug': 'tj-sokol-husovice',
    'name': 'TJ Sokol Husovice',
    'address': 'Dukelská 1, Brno',
    'fetched_at': '2026-09-20T10:00:00+00:00',
  });

  final noContact = Venue.fromJson(const {
    'id': 'v3',
    'slug': 'bez-kontaktu',
    'name': 'Kuželna bez kontaktu',
    'fetched_at': '2026-09-21T08:00:00+00:00',
  });

  Widget app({
    required Widget home,
    List<Venue> venues = const [],
  }) => ProviderScope(
    overrides: [venuesProvider.overrideWith((ref) => Stream.value(venues))],
    child: MaterialApp(home: home),
  );

  group('VenuesScreen', () {
    testWidgets('lists venues alphabetically with name and address', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(home: const VenuesScreen(), venues: [brnoIv, husovice]),
      );
      await tester.pumpAndSettle();

      final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
      expect(tiles, hasLength(2));
      expect((tiles[0].title as Text).data, 'TJ Sokol Brno IV');
      expect((tiles[1].title as Text).data, 'TJ Sokol Husovice');
      expect((tiles[0].subtitle as Text).data, brnoIv.address);
    });

    testWidgets('search filters accent-insensitively', (tester) async {
      await tester.pumpWidget(
        app(home: const VenuesScreen(), venues: [brnoIv, husovice]),
      );
      await tester.pumpAndSettle();

      // "Dukelská" — accented, in husovice's address only (brnoIv's own
      // club list happens to include "TJ Sokol Husovice", so filtering by
      // that name would match both venues by design of venuesMatching).
      await tester.enterText(find.byType(TextField), 'dukelSKA');
      await tester.pumpAndSettle();

      expect(find.text('TJ Sokol Husovice'), findsOneWidget);
      expect(find.text('TJ Sokol Brno IV'), findsNothing);

      await tester.enterText(find.byType(TextField), ' dukelská');
      await tester.pumpAndSettle();
      expect(find.text('TJ Sokol Husovice'), findsOneWidget);
    });

    testWidgets('empty state shown when there are no venues yet', (
      tester,
    ) async {
      await tester.pumpWidget(app(home: const VenuesScreen()));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Zatím žádné kuželny — objeví se po první synchronizaci zápasů.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('tapping a row opens the venue detail screen', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(home: const VenuesScreen(), venues: [brnoIv]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('TJ Sokol Brno IV'));
      await tester.pumpAndSettle();

      expect(find.byType(VenueDetailScreen), findsOneWidget);
      expect(
        find.widgetWithText(AppBar, 'TJ Sokol Brno IV'),
        findsOneWidget,
      );
    });
  });

  group('VenueDetailScreen', () {
    testWidgets('while venues are loading shows a progress indicator', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            venuesProvider.overrideWith((ref) => const Stream.empty()),
          ],
          child: const MaterialApp(
            home: VenueDetailScreen(slug: 'tj-sokol-brno-iv'),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('a slug not found shows the not-found message', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          home: const VenueDetailScreen(slug: 'nikde'),
          venues: [brnoIv],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Kuželna nenalezena.'), findsOneWidget);
    });

    testWidgets(
      'shows Zavolat/Napsat e-mail/Navigovat only when the data exists, and '
      'calls the injected launchers',
      (tester) async {
        final called = <String>[];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              venuesProvider.overrideWith((ref) => Stream.value([brnoIv])),
            ],
            child: MaterialApp(
              home: VenueDetailScreen(
                slug: 'tj-sokol-brno-iv',
                callPhone: (v) => called.add('call:$v'),
                sendEmail: (v) => called.add('email:$v'),
                openUrl: (v) => called.add('url:$v'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(_filledButtonWithText('Zavolat'), findsOneWidget);
        expect(_filledButtonWithText('Napsat e-mail'), findsOneWidget);
        expect(_filledButtonWithText('Navigovat'), findsOneWidget);

        await tester.tap(find.text('Zavolat'));
        await tester.tap(find.text('Napsat e-mail'));
        await tester.tap(find.text('Navigovat'));
        await tester.pumpAndSettle();

        expect(called, [
          'call:736435492',
          'email:kuzelkybrnoiv@email.cz',
          'url:https://www.google.com/maps/search/?api=1&query=49.1891783,16.6354503',
        ]);
      },
    );

    testWidgets('no phone/e-mail/coordinates hides the buttons', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          home: const VenueDetailScreen(slug: 'bez-kontaktu'),
          venues: [noContact],
        ),
      );
      await tester.pumpAndSettle();

      expect(_filledButtonWithText('Zavolat'), findsNothing);
      expect(_filledButtonWithText('Napsat e-mail'), findsNothing);
      expect(_filledButtonWithText('Navigovat'), findsNothing);
    });

    testWidgets('Adresa/Telefon/E-mail rows show the values', (tester) async {
      await tester.pumpWidget(
        app(
          home: const VenueDetailScreen(slug: 'tj-sokol-brno-iv'),
          venues: [brnoIv],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(ListTile, 'Adresa'), findsOneWidget);
      expect(find.text(brnoIv.address!), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Telefon'), findsOneWidget);
      expect(find.text('736435492'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'E-mail'), findsOneWidget);
      expect(find.text('kuzelkybrnoiv@email.cz'), findsOneWidget);
    });

    testWidgets('tapping the Telefon row also calls the launcher', (
      tester,
    ) async {
      final called = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            venuesProvider.overrideWith((ref) => Stream.value([brnoIv])),
          ],
          child: MaterialApp(
            home: VenueDetailScreen(
              slug: 'tj-sokol-brno-iv',
              callPhone: (v) => called.add('call:$v'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ListTile, 'Telefon'));
      await tester.pumpAndSettle();

      expect(called, ['call:736435492']);
    });

    testWidgets('a section renders as a titled card with label/value rows', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          home: const VenueDetailScreen(slug: 'tj-sokol-brno-iv'),
          venues: [brnoIv],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Technické informace'), findsOneWidget);
      expect(find.text('Dráhy'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(find.text('Kuželky'), findsOneWidget);
      expect(find.text('Syndur TOP'), findsOneWidget);
      expect(find.text('Stavěč kuželek'), findsOneWidget);
      expect(find.text('Pro-Tec K800'), findsOneWidget);
    });

    testWidgets(
      'a long section value wraps instead of overflowing the card at the '
      'largest text size on a phone',
      (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final kolaudace = Venue.fromJson(const {
          'id': 'v4',
          'slug': 'kolaudace',
          'name': 'Kuželna s kolaudací',
          'sections': [
            {
              'title': 'Kolaudační informace',
              'items': [
                {
                  'label': 'Kolaudace / platnost',
                  'value': '12. 9. 2025 / do 11. 9. 2028',
                },
              ],
            },
          ],
          'fetched_at': '2026-09-20T10:00:00+00:00',
        });
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: app(
              home: const VenueDetailScreen(slug: 'kolaudace'),
              venues: [kolaudace],
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('12. 9. 2025 / do 11. 9. 2028'), findsOneWidget);
      },
    );

    testWidgets('Kluby lists the club names', (tester) async {
      await tester.pumpWidget(
        app(
          home: const VenueDetailScreen(slug: 'tj-sokol-brno-iv'),
          venues: [brnoIv],
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('Kluby'), 200);
      await tester.pumpAndSettle();

      expect(find.text('Kluby'), findsOneWidget);
      for (final club in brnoIv.clubs) {
        // The venue's own name also appears once in the AppBar, so it
        // matches twice; every other club name is unique to the list.
        final expectedCount = club == brnoIv.name ? 2 : 1;
        expect(find.text(club), findsNWidgets(expectedCount));
      }
    });

    testWidgets('footer shows the source and fetched-at day, with a link '
        'to the site', (tester) async {
      final launched = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            venuesProvider.overrideWith((ref) => Stream.value([brnoIv])),
          ],
          child: MaterialApp(
            home: VenueDetailScreen(
              slug: 'tj-sokol-brno-iv',
              openUrl: launched.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final footerText =
          'Údaje z vysledky.kuzelky.cz · aktualizováno '
          '${dayLabel(Day.fromDateTime(brnoIv.fetchedAt))}';
      await tester.scrollUntilVisible(find.text(footerText), 200);
      await tester.pumpAndSettle();

      expect(find.text(footerText), findsOneWidget);

      await tester.tap(find.text('Na webu ČKA'));
      await tester.pumpAndSettle();

      expect(launched, [
        'https://vysledky.kuzelky.cz/detail-kuzelny/tj-sokol-brno-iv',
      ]);
    });
  });
}
