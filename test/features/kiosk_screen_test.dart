import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/data/open_meteo.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/kiosk_header.dart';
import 'package:rezervator/domain/kiosk_layout.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/kiosk_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Verifies the kiosk theme `SwitchListTile` calls Api.setKioskDark, which
/// PATCHes `schedule_settings.kiosk_dark` — asserted here by inspecting the
/// stubbed HTTP request rather than hitting a real backend.
void main() {
  /// [text] inside the admin tile titled [title] — the warning and the
  /// booking note each have their own „Přidat…“ and „Upravit…“.
  Finder inTile(String title, String text) => find.descendant(
    of: find.widgetWithText(ListTile, title),
    matching: find.text(text),
  );

  /// The admin section titled [title] (keyed by its title) — „Nástěnka“
  /// is a row of the Záhlaví and the Panely tables too, „Zápasy“ of
  /// Panely.
  Finder section(String title) => find.byKey(ValueKey('section:$title'));

  /// [finder] within the section titled [title].
  Finder inSection(String title, Finder finder) =>
      find.descendant(of: section(title), matching: finder);

  const admin = Profile(
    id: 'admin1',
    displayName: 'Správce',
    email: 'admin@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );

  const defaults0 = ScheduleSettings(
    laneCount: 4,
    trainingWeekdays: {1, 2, 4},
    bookingHorizonDays: 14,
    maxActiveReservations: 3,
    kioskDark: true,
  );

  late List<http.Request> requests;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final mock = MockClient((request) async {
      requests.add(request);
      return http.Response('{}', 200,
          headers: {'content-type': 'application/json'});
    });
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test-anon-key',
      httpClient: mock,
      authOptions: const FlutterAuthClientOptions(
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
      ),
    );
  });

  setUp(() => requests = []);

  // The page is long (the panel options sit above the address): a tall
  // window keeps every section built.
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 6800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget app({
    List<Profile> roster = const [admin],
    Future<String> Function(String)? resetPassword,
    ScheduleSettings? settings,
    Venue? alleyVenue,
    http.Client? openMeteo,
  }) {
    final shown = settings ?? defaults0;
    return ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(admin)),
        settingsProvider.overrideWith((ref) => Stream.value(shown)),
        clubsProvider.overrideWith((ref) => Stream.value(const [])),
        profilesProvider.overrideWith((ref) => Stream.value(roster)),
        if (alleyVenue != null) ...[
          federationSyncProvider.overrideWith(
            (ref) => Stream.value(FederationSync(venueSlug: alleyVenue.slug)),
          ),
          venuesProvider.overrideWith((ref) => Stream.value([alleyVenue])),
        ],
        if (openMeteo != null)
          openMeteoClientProvider.overrideWithValue(openMeteo),
      ],
      child: MaterialApp(
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('cs'), Locale('en')],
        home: KioskSettingsScreen(
          resetPassword:
              resetPassword ?? (_) async => 'abcd-efgh-jkmn-pqrt',
        ),
      ),
    );
  }

  testWidgets(
      'toggling "Tmavý režim" PATCHes schedule_settings.kiosk_dark',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Tmavý režim'), findsOneWidget);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Tmavý režim'));
    await tester.pumpAndSettle();

    final patch = requests.firstWhere(
      (r) => r.method == 'PATCH' && r.url.path.contains('schedule_settings'),
    );
    final body = jsonDecode(patch.body) as Map<String, dynamic>;
    // Started `true` (dark); toggling flips it to `false`.
    expect(body['kiosk_dark'], false);
  });

  testWidgets(
      'toggling "Celý den na obrazovku" PATCHes '
      'schedule_settings.kiosk_fit_day', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final tile =
        find.widgetWithText(SwitchListTile, 'Celý den na obrazovku');
    expect(tile, findsOneWidget);
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();

    final patch = requests.firstWhere(
      (r) =>
          r.method == 'PATCH' &&
          r.url.path.contains('schedule_settings') &&
          r.body.contains('kiosk_fit_day'),
    );
    final body = jsonDecode(patch.body) as Map<String, dynamic>;
    // Started `true` (fit); toggling flips it to `false` (scroll mode).
    expect(body['kiosk_fit_day'], false);
  });

  testWidgets('kiosk accounts are administered here, not among Hráči',
      (tester) async {
    tall(tester);
    const kiosk = Profile(
      id: 'k1',
      displayName: 'Kiosk u dráhy',
      email: 'kiosk@veverky.cz',
      role: Role.kiosk,
      status: ProfileStatus.approved,
    );
    await tester.pumpWidget(app(roster: const [admin, kiosk]));
    await tester.pumpAndSettle();

    expect(find.text('Kioskové účty'), findsOneWidget);
    expect(find.text('Kiosk u dráhy'), findsOneWidget);
    expect(find.text('kiosk@veverky.cz'), findsOneWidget);
    // Only kiosk accounts — the admin is a person and belongs in Hráči.
    expect(find.text('Správce'), findsNothing);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vrátit mezi hráče'));
    await tester.pumpAndSettle();

    final call = requests.last;
    expect(call.url.path, endsWith('/rpc/set_role'));
    expect(jsonDecode(call.body), {'p_user_id': 'k1', 'p_role': 'player'});
  });

  testWidgets('a new kiosk password is asked for, then shown once',
      (tester) async {
    tall(tester);
    const kiosk = Profile(
      id: 'k1',
      displayName: 'Kiosk u dráhy',
      email: 'kiosk@veverky.cz',
      role: Role.kiosk,
      status: ProfileStatus.approved,
    );
    final asked = <String>[];
    await tester.pumpWidget(app(
      roster: const [admin, kiosk],
      resetPassword: (id) async {
        asked.add(id);
        return 'abcd-efgh-jkmn-pqrt';
      },
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nastavit nové heslo…'));
    await tester.pumpAndSettle();

    // Asked first: the current password stops working.
    expect(find.text('Nastavit nové heslo?'), findsOneWidget);
    expect(find.textContaining('přestane platit'), findsOneWidget);
    await tester.tap(find.text('Nastavit'));
    await tester.pumpAndSettle();

    // The answer is shown once, with the login it belongs to.
    expect(asked, ['k1']);
    expect(find.text('Nové heslo kiosku'), findsOneWidget);
    expect(find.text('abcd-efgh-jkmn-pqrt'), findsOneWidget);
    expect(find.text('Přihlašovací jméno: kiosk@veverky.cz'), findsOneWidget);
  });

  testWidgets('a refused reset shows why and no password', (tester) async {
    tall(tester);
    const kiosk = Profile(
      id: 'k1',
      displayName: 'Kiosk u dráhy',
      email: 'kiosk@veverky.cz',
      role: Role.kiosk,
      status: ProfileStatus.approved,
    );
    await tester.pumpWidget(app(
      roster: const [admin, kiosk],
      resetPassword: (_) async => throw Exception('not_allowed'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nastavit nové heslo…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nastavit'));
    await tester.pumpAndSettle();

    expect(find.text('Nové heslo kiosku'), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  // Setting a tablet up needs two things from this screen: where to point
  // its browser, and an account to log in with. The address is derived from
  // where the app runs (kioskUrlFrom), so the test asserts the route and
  // the clipboard, not a hard-coded host.
  testWidgets('the kiosk address is shown and copies to the clipboard',
      (tester) async {
    tall(tester);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Adresa pro tablet'), findsOneWidget);
    final shown = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .data!;
    expect(shown, endsWith('/#/kiosk-login'));

    await tester.tap(find.byIcon(Icons.copy_outlined));
    await tester.pumpAndSettle();
    expect(copied, shown);
    expect(find.text('Adresa zkopírována.'), findsOneWidget);
  });

  testWidgets('without a kiosk account the section explains how to make one',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Kioskové účty'), findsOneWidget);
    expect(find.textContaining('Nastavit jako kiosk'), findsOneWidget);
    expect(find.text('Vrátit mezi hráče'), findsNothing);
  });

  group('header (0081)', () {
    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;
    int patches() => requests.where((r) => r.method == 'PATCH').length;
    final sokol = Venue(
      id: 'v1',
      slug: 'tj-sokol-brno-iv',
      name: 'TJ Sokol Brno IV',
      address: 'Štolcova 551/8, 61800 Brno',
      lat: 49.1891783,
      lng: 16.6354503,
      fetchedAt: DateTime(2026, 9, 1),
    );

    /// The weather on the left, the rest the default.
    final weatherLeft = KioskHeader.defaults.withSide(
      KioskHeaderModule.weather,
      PanelSide.left,
    );

    /// The settings with [header], everything else the default.
    ScheduleSettings laid(
      KioskHeader header, {
      String? place,
      double? lat,
      double? lon,
      String? title,
      bool todays = true,
    }) => ScheduleSettings(
      laneCount: 4,
      trainingWeekdays: const {1, 2, 4},
      bookingHorizonDays: 14,
      maxActiveReservations: 3,
      kioskHeader: header,
      kioskWeatherPlace: place,
      kioskWeatherLat: lat,
      kioskWeatherLon: lon,
      kioskWeatherTitle: title,
      kioskTodaysMatches: todays,
      tenantId: 't',
    );

    /// [header] the way a PATCH carries it.
    Object? patched(KioskHeader header) =>
        jsonDecode(jsonEncode(header.toJson()));

    /// The ids on [side] in the last PATCH's layout, in order.
    List<Object?> patchedOn(String side) => [
      for (final m
          in ((lastPatch()['kiosk_header'] as Map)['modules'] as List)
              .cast<Map>())
        if (m['side'] == side) m['id'],
    ];

    Finder headerRow(String id) =>
        find.byKey(ValueKey('kiosk-header-module:$id'));
    Finder inRow(Finder row, Finder finder) =>
        find.descendant(of: row, matching: finder);
    Finder sideList(String id) => inRow(
      headerRow(id),
      find.byWidgetPredicate((w) => w is DropdownButtonFormField),
    );
    IconButton arrow(WidgetTester tester, String id, IconData icon) =>
        tester.widget<IconButton>(
          inRow(headerRow(id), find.widgetWithIcon(IconButton, icon)),
        );

    /// Opens the „Poloha“ list of the row [id], now showing [now], and
    /// picks [to].
    Future<void> place(
      WidgetTester tester,
      String id,
      String now,
      String to,
    ) async {
      final current = inRow(headerRow(id), find.text(now));
      await tester.ensureVisible(current);
      await tester.tap(current);
      await tester.pumpAndSettle();
      await tester.tap(find.text(to).last);
      await tester.pumpAndSettle();
    }

    testWidgets('one section „Záhlaví“: the clock first and fixed, the '
        'modules in the layout\'s order with their place, today\'s matches '
        'last in the centre; the head over the columns', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(
        inSection(
          'Záhlaví',
          find.text(
            'Pruh nahoře na kiosku. Každý modul má nadpis a pod ním údaj. '
            'Moduly vlevo jsou hned za hodinami, vpravo před tlačítkem '
            '„Rezervace tréninku“; dnešní zápasy jsou uprostřed — domácí '
            'nahoře, venkovní pod nimi.',
          ),
        ),
        findsOneWidget,
      );
      double top(Finder f) => tester.getTopLeft(f).dy;
      final tops = <double>[];
      for (final (id, name, side) in [
        ('clock', 'Hodiny a datum', 'Vlevo, vždy první'),
        ('weather', 'Počasí', 'Vypnuto'),
        ('nameday', 'Svátek', 'Vypnuto'),
        ('duty', 'Služba na kantýně', 'Vypnuto'),
        ('notices', 'Nástěnka', 'Vpravo'),
        ('matches', 'Dnešní zápasy', 'Uprostřed'),
      ]) {
        final row = headerRow(id);
        expect(inSection('Záhlaví', row), findsOneWidget, reason: id);
        expect(inRow(row, find.text(name)), findsOneWidget, reason: id);
        expect(inRow(row, find.text(side)), findsOneWidget, reason: id);
        tops.add(top(row));
      }
      for (var i = 1; i < tops.length; i++) {
        expect(tops[i - 1], lessThan(tops[i]), reason: 'row $i');
      }
      // The clock is neither moved nor switched off.
      expect(sideList('clock'), findsNothing);
      expect(inRow(headerRow('clock'), find.byType(IconButton)), findsNothing);
      // A module off has no arrows; alone on its side one cannot move;
      // today's matches have no order.
      for (final id in ['weather', 'nameday', 'duty', 'matches']) {
        expect(inRow(headerRow(id), find.byType(IconButton)), findsNothing,
            reason: id);
      }
      expect(arrow(tester, 'notices', Icons.arrow_upward).onPressed, isNull);
      expect(arrow(tester, 'notices', Icons.arrow_downward).onPressed, isNull);

      // Wide enough for one-line rows: the head above them, each label
      // over its column.
      final head = find.byKey(const ValueKey('kiosk-header-modules-header'));
      expect(inSection('Záhlaví', head), findsOneWidget);
      for (final label in ['Modul', 'Poloha', 'Pořadí']) {
        expect(inRow(head, find.text(label)), findsOneWidget, reason: label);
      }
      expect(top(head), lessThan(tops.first));
      final sideX = tester.getTopLeft(inRow(head, find.text('Poloha'))).dx;
      for (final id in ['weather', 'notices', 'matches']) {
        expect(tester.getTopLeft(sideList(id)).dx, sideX, reason: id);
      }
      expect(
        tester
            .getTopLeft(
              inRow(headerRow('clock'), find.text('Vlevo, vždy první')),
            )
            .dx,
        sideX,
      );
      Rect arrowRect(IconData icon) => tester.getRect(
        inRow(headerRow('notices'), find.widgetWithIcon(IconButton, icon)),
      );
      final up = arrowRect(Icons.arrow_upward);
      final down = arrowRect(Icons.arrow_downward);
      expect(
        (up.left + down.right) / 2,
        closeTo(tester.getCenter(inRow(head, find.text('Pořadí'))).dx, 0.5),
      );

      // What the data are, under the table.
      expect(
        inSection(
          'Záhlaví',
          find.text(
            'Počasí: ČHMÚ (model ALADIN) přes Open-Meteo.com (CC BY 4.0), '
            'obnovuje se každou půlhodinu; zdroj kiosk ukáže po ťuknutí na '
            'počasí. Svátek podle českého kalendáře; ve státní svátek bez '
            'jména jeho název. Služba podle plánu ve Správě → Služby; ťuk '
            'ukáže plán.',
          ),
        ),
        findsOneWidget,
      );
      // One place for the header: the old section and switches are gone.
      expect(section('Stavový řádek'), findsNothing);
      expect(find.text('Dnešní zápasy v záhlaví'), findsNothing);
      expect(find.widgetWithText(SwitchListTile, 'Počasí'), findsNothing);
      expect(find.widgetWithText(SwitchListTile, 'Svátek'), findsNothing);
      expect(find.widgetWithText(SwitchListTile, 'V záhlaví'), findsNothing);
    });

    testWidgets('a module goes left, right or off from its list: the PATCH '
        'is the whole layout', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await place(tester, 'nameday', 'Vypnuto', 'Vlevo');
      expect(lastPatch(), {
        'kiosk_header': patched(
          KioskHeader.defaults.withSide(
            KioskHeaderModule.nameday,
            PanelSide.left,
          ),
        ),
      });

      await place(tester, 'duty', 'Vypnuto', 'Vpravo');
      expect(lastPatch(), {
        'kiosk_header': patched(
          KioskHeader.defaults.withSide(
            KioskHeaderModule.duty,
            PanelSide.right,
          ),
        ),
      });

      await place(tester, 'notices', 'Vpravo', 'Vypnuto');
      expect(lastPatch(), {
        'kiosk_header': patched(
          KioskHeader.defaults.withSide(
            KioskHeaderModule.notices,
            PanelSide.off,
          ),
        ),
      });
    });

    testWidgets('↑↓ move a module among the placed ones of its side: the '
        'first cannot go up, the last cannot go down', (tester) async {
      tall(tester);
      final both = weatherLeft.withSide(
        KioskHeaderModule.nameday,
        PanelSide.left,
      );
      await tester.pumpWidget(app(settings: laid(both)));
      await tester.pumpAndSettle();

      expect(arrow(tester, 'weather', Icons.arrow_upward).onPressed, isNull);
      expect(
        arrow(tester, 'weather', Icons.arrow_downward).onPressed,
        isNotNull,
      );
      expect(arrow(tester, 'nameday', Icons.arrow_upward).onPressed, isNotNull);
      expect(arrow(tester, 'nameday', Icons.arrow_downward).onPressed, isNull);
      // The notices are alone on the right.
      expect(arrow(tester, 'notices', Icons.arrow_upward).onPressed, isNull);
      expect(arrow(tester, 'notices', Icons.arrow_downward).onPressed, isNull);

      final down = inRow(headerRow('weather'), find.byTooltip('Posunout níž'));
      await tester.ensureVisible(down);
      await tester.tap(down);
      await tester.pumpAndSettle();
      expect(lastPatch(), {
        'kiosk_header': patched(both.moved(KioskHeaderModule.weather, 1)),
      });
      expect(patchedOn('left'), ['nameday', 'weather']);

      await tester.tap(
        inRow(headerRow('nameday'), find.byTooltip('Posunout výš')),
      );
      await tester.pumpAndSettle();
      expect(lastPatch(), {
        'kiosk_header': patched(both.moved(KioskHeaderModule.nameday, -1)),
      });
    });

    testWidgets('today\'s matches: in the centre by default; „Vypnuto“ '
        'PATCHes kiosk_todays_matches, „Uprostřed“ puts them back', (
      tester,
    ) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await place(tester, 'matches', 'Uprostřed', 'Vypnuto');
      expect(lastPatch(), {'kiosk_todays_matches': false});

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        app(settings: laid(KioskHeader.defaults, todays: false)),
      );
      await tester.pumpAndSettle();
      await place(tester, 'matches', 'Vypnuto', 'Uprostřed');
      expect(lastPatch(), {'kiosk_todays_matches': true});
    });

    testWidgets('placing the weather takes the alley\'s venue as its place '
        'when none was picked — in the same PATCH', (tester) async {
      tall(tester);
      await tester.pumpWidget(app(alleyVenue: sokol));
      await tester.pumpAndSettle();
      expect(find.text('Místo pro počasí'), findsNothing);
      expect(find.text('Nadpis počasí'), findsNothing);

      await place(tester, 'weather', 'Vypnuto', 'Vlevo');
      expect(lastPatch(), {
        'kiosk_header': patched(weatherLeft),
        'kiosk_weather_place': 'TJ Sokol Brno IV, Štolcova 551/8, 61800 Brno',
        'kiosk_weather_lat': 49.1891783,
        'kiosk_weather_lon': 16.6354503,
      });
    });

    testWidgets('placing the weather again keeps the place the admin picked '
        '— the venue does not overwrite it', (tester) async {
      tall(tester);
      await tester.pumpWidget(
        app(
          alleyVenue: sokol,
          settings: laid(
            KioskHeader.defaults,
            place: 'Brno, Jihomoravský',
            lat: 49.19522,
            lon: 16.60796,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await place(tester, 'weather', 'Vypnuto', 'Vpravo');
      expect(lastPatch(), {
        'kiosk_header': patched(
          KioskHeader.defaults.withSide(
            KioskHeaderModule.weather,
            PanelSide.right,
          ),
        ),
      });
    });

    testWidgets('without a known venue placing the weather writes only the '
        'layout; the place row says it is missing', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await place(tester, 'weather', 'Vypnuto', 'Vlevo');
      expect(lastPatch(), {'kiosk_header': patched(weatherLeft)});
    });

    testWidgets('the weather placed: its place and its title under the '
        'table, the title „Počasí (výchozí)“ until the admin types one', (
      tester,
    ) async {
      tall(tester);
      await tester.pumpWidget(app(settings: laid(weatherLeft)));
      await tester.pumpAndSettle();

      final where = find.widgetWithText(ListTile, 'Místo pro počasí');
      final title = find.widgetWithText(ListTile, 'Nadpis počasí');
      expect(inSection('Záhlaví', where), findsOneWidget);
      expect(inSection('Záhlaví', title), findsOneWidget);
      double top(Finder f) => tester.getTopLeft(f).dy;
      expect(top(where), greaterThan(top(headerRow('matches'))));
      expect(top(title), greaterThan(top(where)));
      expect(
        find.text('Není vybrané — kiosk počasí neukáže.'),
        findsOneWidget,
      );
      expect(inTile('Nadpis počasí', 'Počasí (výchozí)'), findsOneWidget);
      expect(inTile('Nadpis počasí', 'Upravit…'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        app(settings: laid(weatherLeft, title: 'Dnes v Brně')),
      );
      await tester.pumpAndSettle();
      expect(inTile('Nadpis počasí', 'Dnes v Brně'), findsOneWidget);
    });

    testWidgets('„Nadpis počasí“: typed in a dialog starting from the '
        'default, at most 40 characters, saved trimmed; „Zrušit“ writes '
        'nothing', (tester) async {
      tall(tester);
      await tester.pumpWidget(app(settings: laid(weatherLeft)));
      await tester.pumpAndSettle();

      final edit = inTile('Nadpis počasí', 'Upravit…');
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Nadpis počasí'),
        ),
        findsOneWidget,
      );
      final field = find.widgetWithText(TextField, 'Nadpis');
      expect(tester.widget<TextField>(field).controller!.text, 'Počasí');
      expect(tester.widget<TextField>(field).maxLength, 40);
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();
      expect(patches(), 0);

      await tester.tap(edit);
      await tester.pumpAndSettle();
      await tester.enterText(field, '  Dnes v Brně ');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Uložit'));
      await tester.pumpAndSettle();
      expect(lastPatch(), {'kiosk_weather_title': 'Dnes v Brně'});
    });

    testWidgets('„Nadpis počasí“ back to the default is stored as none', (
      tester,
    ) async {
      tall(tester);
      await tester.pumpWidget(
        app(settings: laid(weatherLeft, title: 'Dnes v Brně')),
      );
      await tester.pumpAndSettle();

      final edit = inTile('Nadpis počasí', 'Upravit…');
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      final field = find.widgetWithText(TextField, 'Nadpis');
      expect(tester.widget<TextField>(field).controller!.text, 'Dnes v Brně');
      await tester.tap(find.text('Výchozí text'));
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, 'Počasí');
      await tester.tap(find.widgetWithText(FilledButton, 'Uložit'));
      await tester.pumpAndSettle();
      expect(lastPatch(), {'kiosk_weather_title': null});

      // Typed out by hand, with spaces, too.
      await tester.tap(edit);
      await tester.pumpAndSettle();
      await tester.enterText(field, ' Počasí  ');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Uložit'));
      await tester.pumpAndSettle();
      expect(lastPatch(), {'kiosk_weather_title': null});
    });

    // A fresh tree: a second pumpWidget never swaps the overrides.
    testWidgets('a place found by name: the results Czech-sorted, the pick '
        'PATCHes the three columns', (tester) async {
      tall(tester);
      Uri? asked;
      final openMeteo = MockClient((req) async {
        asked = req.url;
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            // Czech order differs from code units twice here: „Ch“ comes
            // after „H“, „Č“ before „D“.
            'results': [
              {
                'name': 'Chrlice',
                'latitude': 49.13,
                'longitude': 16.65,
                'country_code': 'CZ',
                'admin1': 'Jihomoravský',
              },
              {
                'name': 'Dubňany',
                'latitude': 48.92,
                'longitude': 17.09,
                'country_code': 'CZ',
                'admin1': 'Jihomoravský',
              },
              {
                'name': 'Brno',
                'latitude': 49.19522,
                'longitude': 16.60796,
                'country_code': 'CZ',
                'admin1': 'Jihomoravský',
              },
              {
                'name': 'Hodonín',
                'latitude': 48.85,
                'longitude': 17.13,
                'country_code': 'CZ',
                'admin1': 'Jihomoravský',
              },
              {
                'name': 'Čejč',
                'latitude': 48.95,
                'longitude': 16.96,
                'country_code': 'CZ',
                'admin1': 'Jihomoravský',
              },
            ],
          })),
          200,
        );
      });
      await tester.pumpWidget(
        app(
          settings: laid(weatherLeft),
          alleyVenue: sokol,
          openMeteo: openMeteo,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Není vybrané — kiosk počasí neukáže.'),
        findsOneWidget,
      );

      await tester.ensureVisible(find.text('Vybrat…'));
      await tester.tap(find.text('Vybrat…'));
      await tester.pumpAndSettle();
      // The alley's venue is offered first.
      expect(
        find.text('TJ Sokol Brno IV, Štolcova 551/8, 61800 Brno'),
        findsOneWidget,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Hledat obec nebo město'),
        'Brn',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(asked?.queryParameters['name'], 'Brn');
      final labels = [
        for (final t in tester.widgetList<ListTile>(
          find.descendant(
            of: find.byType(ListView).last,
            matching: find.byType(ListTile),
          ),
        ))
          ((t.title! as Text).data!),
      ];
      expect(labels, [
        'Brno, Jihomoravský',
        'Čejč, Jihomoravský',
        'Dubňany, Jihomoravský',
        'Hodonín, Jihomoravský',
        'Chrlice, Jihomoravský',
      ]);

      await tester.tap(find.text('Brno, Jihomoravský'));
      await tester.pumpAndSettle();
      expect(lastPatch(), {
        'kiosk_weather_place': 'Brno, Jihomoravský',
        'kiosk_weather_lat': 49.19522,
        'kiosk_weather_lon': 16.60796,
      });
    });

    testWidgets('one search at a time: Enter again while one runs asks '
        'nothing more', (tester) async {
      tall(tester);
      var asked = 0;
      final answer = Completer<http.Response>();
      await tester.pumpWidget(
        app(
          settings: laid(weatherLeft),
          openMeteo: MockClient((_) {
            asked++;
            return answer.future;
          }),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Vybrat…'));
      await tester.tap(find.text('Vybrat…'));
      await tester.pumpAndSettle();
      final field = find.widgetWithText(TextField, 'Hledat obec nebo město');
      await tester.enterText(field, 'Brno');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      // Back into the field (the search took the focus) and Enter again.
      await tester.tap(field);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.tap(find.byTooltip('Hledat'));
      await tester.pump();
      expect(asked, 1);

      answer.complete(
        http.Response.bytes(utf8.encode(jsonEncode({'results': []})), 200),
      );
      await tester.pumpAndSettle();
      expect(find.text('Nic nenalezeno.'), findsOneWidget);
    });

    testWidgets('a failed search says so and keeps the dialog', (tester) async {
      tall(tester);
      await tester.pumpWidget(
        app(
          settings: laid(weatherLeft),
          openMeteo: MockClient((_) async => http.Response('', 503)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Vybrat…'));
      await tester.tap(find.text('Vybrat…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Hledat obec nebo město'),
        'Brno',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.textContaining('Hledání se nepovedlo'), findsOneWidget);
      expect(find.text('Místo pro počasí'), findsWidgets);
      expect(requests.where((r) => r.method == 'PATCH'), isEmpty);
    });

    testWidgets('a module of a newer app is not listed and goes back '
        'unchanged with every PATCH', (tester) async {
      tall(tester);
      await tester.pumpWidget(app(
        settings: laid(
          KioskHeader.fromJson({
            'modules': [
              {'id': 'weather', 'side': 'off'},
              {'id': 'radar', 'side': 'left', 'x': 1},
              {'id': 'nameday', 'side': 'off'},
              {'id': 'duty', 'side': 'off'},
              {'id': 'notices', 'side': 'right'},
            ],
          }),
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        inSection('Záhlaví', find.byType(DropdownButtonFormField<PanelSide>)),
        findsNWidgets(4),
      );
      expect(headerRow('radar'), findsNothing);

      await place(tester, 'nameday', 'Vypnuto', 'Vlevo');
      final modules =
          (lastPatch()['kiosk_header'] as Map)['modules'] as List;
      expect(modules, hasLength(5));
      expect(modules[1], {'id': 'radar', 'side': 'left', 'x': 1});
      expect(modules[2], {'id': 'nameday', 'side': 'left'});
    });

    testWidgets('on a phone a row is two lines: the name, under it the '
        'place and the arrows', (tester) async {
      // Narrower than the table's one-line width (520 inside the page's
      // padding).
      tester.view.physicalSize = const Size(500, 8000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        app(
          settings: laid(
            weatherLeft.withSide(KioskHeaderModule.nameday, PanelSide.left),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final row = headerRow('weather');
      await tester.ensureVisible(row);
      final name = inRow(row, find.text('Počasí'));
      final list = sideList('weather');
      final down = inRow(row, find.byTooltip('Posunout níž'));
      expect(down, findsOneWidget);
      expect(
        tester.getTopLeft(list).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(name).dy),
      );
      expect(
        tester.getCenter(down).dy,
        greaterThan(tester.getBottomLeft(name).dy),
      );
      // No head on two-line rows: each list says what it is.
      expect(
        find.byKey(const ValueKey('kiosk-header-modules-header')),
        findsNothing,
      );
      expect(inRow(row, find.text('Poloha')), findsOneWidget);
      // The clock's fixed place goes under its name too.
      expect(
        tester
            .getTopLeft(
              inRow(headerRow('clock'), find.text('Vlevo, vždy první')),
            )
            .dy,
        greaterThanOrEqualTo(
          tester
              .getBottomLeft(
                inRow(headerRow('clock'), find.text('Hodiny a datum')),
              )
              .dy,
        ),
      );
    });
  });

  group('warning', () {
    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;

    testWidgets('none yet: „Přidat…“ asks for the text, blank cannot be '
        'saved, the text is saved trimmed', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.textContaining('Žádné. Varování'), findsOneWidget);
      // In the screen section, first.
      expect(
        tester.getTopLeft(find.text('Upozornění')).dy,
        greaterThan(tester.getTopLeft(find.text('Obrazovka kiosku')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Upozornění')).dy,
        lessThan(tester.getTopLeft(find.text('Tmavý režim')).dy),
      );
      expect(find.byTooltip('Odstranit upozornění'), findsNothing);

      await tester.tap(inTile('Upozornění', 'Přidat…'));
      await tester.pumpAndSettle();
      final save = find.widgetWithText(FilledButton, 'Uložit');
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await tester.enterText(
        find.widgetWithText(TextField, 'Text upozornění'),
        '   ',
      );
      await tester.pump();
      expect(tester.widget<FilledButton>(save).onPressed, isNull);

      await tester.enterText(
        find.widgetWithText(TextField, 'Text upozornění'),
        '  Dráha 3 je mimo provoz. ',
      );
      await tester.pump();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(lastPatch(), {'kiosk_warning': 'Dráha 3 je mimo provoz.'});
    });

    testWidgets('a warning set: shown, „Upravit…“ starts from it, the bin '
        'removes it', (tester) async {
      tall(tester);
      await tester.pumpWidget(
        app(
          settings: const ScheduleSettings(
            laneCount: 4,
            trainingWeekdays: {1, 2, 4},
            bookingHorizonDays: 14,
            maxActiveReservations: 3,
            kioskWarning: 'Dráha 3 je mimo provoz.',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Dráha 3 je mimo provoz.'), findsOneWidget);

      await tester.tap(inTile('Upozornění', 'Upravit…'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.widgetWithText(TextField, 'Text upozornění'),
            )
            .controller!
            .text,
        'Dráha 3 je mimo provoz.',
      );
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();
      expect(requests.where((r) => r.method == 'PATCH'), isEmpty);

      await tester.tap(find.byTooltip('Odstranit upozornění'));
      await tester.pumpAndSettle();
      expect(lastPatch(), {'kiosk_warning': null});
    });
  });

  testWidgets('„Nástěnka“ has no switch for the header any more — the '
      'Záhlaví table places it; the about text says where', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(
      inSection('Nástěnka', find.widgetWithText(SwitchListTile, 'V záhlaví')),
      findsNothing,
    );
    expect(
      inSection(
        'Nástěnka',
        find.text(
          'Oznamy z nástěnky klubu. Který oznam se na kiosku ukáže, volíš '
          'přímo na nástěnce (⋮ u oznamu). Do záhlaví ji dáš v Záhlaví, do '
          'panelu vlevo nebo vpravo v Panelech (výš).',
        ),
      ),
      findsOneWidget,
    );
    // Where in a panel the notices go is the Panely table's.
    expect(find.text('Kde se oznamy zobrazí'), findsNothing);
  });

  for (final (header, panel, why) in [
    (PanelSide.right, PanelSide.off, 'in the header only'),
    (PanelSide.left, PanelSide.off, 'on the header\'s left only'),
    (PanelSide.off, PanelSide.left, 'in a panel only'),
  ]) {
    testWidgets('the notices\' rotation shows with the notices $why', (
      tester,
    ) async {
      tall(tester);
      await tester.pumpWidget(
        app(
          settings: ScheduleSettings(
            laneCount: 4,
            trainingWeekdays: const {1},
            bookingHorizonDays: 14,
            maxActiveReservations: 3,
            kioskHeader: KioskHeader.defaults.withSide(
              KioskHeaderModule.notices,
              header,
            ),
            kioskPanels: KioskPanels.defaults.withSide(
              KioskModule.notices,
              panel,
            ),
            tenantId: 't',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        inSection(
          'Nástěnka',
          find.widgetWithText(TextField, 'Střídání oznamů'),
        ),
        findsOneWidget,
      );
    });
  }

  group('panels (0077)', () {
    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;
    int patches() => requests.where((r) => r.method == 'PATCH').length;

    /// [panels] the way a PATCH carries it.
    Object? patched(KioskPanels panels) =>
        jsonDecode(jsonEncode(panels.toJson()));

    /// The modules' entries of the last PATCH.
    List<dynamic> patchedModules() =>
        (lastPatch()['kiosk_panels'] as Map)['modules'] as List;

    /// The settings with [panels], everything else the default.
    ScheduleSettings laid(KioskPanels panels) => ScheduleSettings(
      laneCount: 4,
      trainingWeekdays: const {1, 2, 4},
      bookingHorizonDays: 14,
      maxActiveReservations: 3,
      kioskPanels: panels,
      tenantId: 't',
    );

    Finder moduleRow(KioskModule module) =>
        find.byKey(ValueKey('kiosk-module:${module.name}'));
    Finder panelRow(PanelSide side) =>
        find.byKey(ValueKey('kiosk-panel:${side.name}'));
    Finder inRow(Finder row, Finder finder) =>
        find.descendant(of: row, matching: finder);
    Finder share(KioskModule module) =>
        inRow(moduleRow(module), find.widgetWithText(TextField, 'Podíl'));
    Finder width(PanelSide side) =>
        inRow(panelRow(side), find.widgetWithText(TextField, 'Šířka'));
    IconButton arrow(WidgetTester tester, KioskModule module, IconData icon) =>
        tester.widget<IconButton>(
          inRow(moduleRow(module), find.widgetWithIcon(IconButton, icon)),
        );
    String shown(WidgetTester tester, Finder field) =>
        tester.widget<TextField>(field).controller!.text;

    /// Types [text] into [field] and presses Enter.
    Future<void> type(WidgetTester tester, Finder field, String text) async {
      await tester.ensureVisible(field);
      await tester.enterText(field, text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
    }

    /// Opens the panel list of [module], now showing [now], and picks [to].
    Future<void> place(
      WidgetTester tester,
      KioskModule module,
      String now,
      String to,
    ) async {
      final current = inRow(moduleRow(module), find.text(now));
      await tester.ensureVisible(current);
      await tester.tap(current);
      await tester.pumpAndSettle();
      await tester.tap(find.text(to).last);
      await tester.pumpAndSettle();
    }

    testWidgets('the default layout: every module in its order with its '
        'panel, the placed ones with their share; only the right panel has '
        'a row; the sum per panel', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(inSection('Panely', find.text('Panely')), findsOneWidget);
      double top(Finder f) => tester.getTopLeft(f).dy;
      final tops = <double>[];
      for (final (module, name, side) in [
        (KioskModule.duty, 'Služba na kantýně', 'Vypnuto'),
        (KioskModule.notices, 'Nástěnka', 'Vpravo'),
        (KioskModule.matches, 'Zápasy', 'Vpravo'),
        (KioskModule.guide, 'Jak začít', 'Vypnuto'),
        (KioskModule.week, 'Hráči týdne', 'Vypnuto'),
      ]) {
        final row = moduleRow(module);
        expect(inSection('Panely', row), findsOneWidget, reason: name);
        expect(inRow(row, find.text(name)), findsOneWidget, reason: name);
        expect(inRow(row, find.text(side)), findsOneWidget, reason: name);
        tops.add(top(row));
      }
      for (var i = 1; i < tops.length; i++) {
        expect(tops[i - 1], lessThan(tops[i]), reason: 'row $i');
      }
      // Wide enough for one-line rows: the table's head above them, each
      // label over its column.
      final head = find.byKey(const ValueKey('kiosk-modules-header'));
      expect(inSection('Panely', head), findsOneWidget);
      for (final label in ['Modul', 'Panel', 'Podíl', 'Pořadí']) {
        expect(inRow(head, find.text(label)), findsOneWidget, reason: label);
      }
      expect(top(head), lessThan(tops.first));
      expect(
        tester.getTopLeft(inRow(head, find.text('Panel'))).dx,
        tester
            .getTopLeft(
              inRow(
                moduleRow(KioskModule.notices),
                find.byType(DropdownButtonFormField<PanelSide>),
              ),
            )
            .dx,
      );
      expect(
        tester.getTopLeft(inRow(head, find.text('Podíl'))).dx,
        tester.getTopLeft(share(KioskModule.notices)).dx,
      );
      expect(shown(tester, share(KioskModule.notices)), '40');
      expect(shown(tester, share(KioskModule.matches)), '60');
      // An unplaced module has no share and no arrows.
      for (final m in [KioskModule.duty, KioskModule.guide, KioskModule.week]) {
        expect(inRow(moduleRow(m), find.byType(TextField)), findsNothing,
            reason: m.name);
        expect(inRow(moduleRow(m), find.byType(IconButton)), findsNothing,
            reason: m.name);
      }

      // Only the right panel holds modules: only its row, above the table.
      expect(panelRow(PanelSide.left), findsNothing);
      expect(inRow(panelRow(PanelSide.right), find.text('Pravý panel')),
          findsOneWidget);
      expect(top(panelRow(PanelSide.right)),
          lessThan(top(moduleRow(KioskModule.duty))));
      expect(shown(tester, width(PanelSide.right)), '2');
      expect(
        tester
            .widget<SwitchListTile>(
              inRow(panelRow(PanelSide.right), find.byType(SwitchListTile)),
            )
            .value,
        isFalse,
      );

      expect(find.text('Vpravo 100 %'), findsOneWidget);
      expect(find.text('Podíly se přepočítají na celou výšku panelu.'),
          findsOneWidget);
      // One place for the panels: the old section is gone.
      expect(find.text('Postranní panel'), findsNothing);
      expect(find.text('Panel zapnutý'), findsNothing);
    });

    // An IconButton is 48 wide where the platform pads tap targets (the test
    // default, Android) but 40 on desktop, where the table is mostly seen:
    // the columns must line up on both.
    testWidgets('the table\'s columns line up with its head on every '
        'platform, the placed rows with the unplaced ones', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      double left(Finder f) => tester.getTopLeft(f).dx;
      final head = find.byKey(const ValueKey('kiosk-modules-header'));
      final panelX = left(inRow(head, find.text('Panel')));
      final shareX = left(inRow(head, find.text('Podíl')));
      final orderX = tester.getCenter(inRow(head, find.text('Pořadí'))).dx;
      Rect arrowRect(KioskModule m, IconData icon) => tester.getRect(
        inRow(moduleRow(m), find.widgetWithIcon(IconButton, icon)),
      );

      for (final m in KioskModule.values) {
        final panelList = inRow(
          moduleRow(m),
          find.byType(DropdownButtonFormField<PanelSide>),
        );
        expect(left(panelList), panelX, reason: '${m.name} panel list');
      }
      for (final m in [KioskModule.notices, KioskModule.matches]) {
        expect(left(share(m)), shareX, reason: '${m.name} share');
        // The pair of arrows sits in the middle of the „Pořadí“ column,
        // whatever the size of the buttons.
        final up = arrowRect(m, Icons.arrow_upward);
        final down = arrowRect(m, Icons.arrow_downward);
        expect((up.left + down.right) / 2, closeTo(orderX, 0.5),
            reason: '${m.name} arrows');
      }
    },
        variant: TargetPlatformVariant({
          TargetPlatform.android,
          TargetPlatform.macOS,
          TargetPlatform.windows,
        }));

    testWidgets('a module goes into a panel from its list: the PATCH is the '
        'whole layout', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await place(tester, KioskModule.guide, 'Vypnuto', 'Vlevo');
      expect(lastPatch().keys, ['kiosk_panels']);
      expect(
        lastPatch()['kiosk_panels'],
        patched(
          KioskPanels.defaults.withSide(KioskModule.guide, PanelSide.left),
        ),
      );
      expect((lastPatch()['kiosk_panels'] as Map)['left'],
          {'days': 2, 'open': false});
      expect((lastPatch()['kiosk_panels'] as Map)['right'],
          {'days': 2, 'open': false});
      expect(patchedModules(), hasLength(5));
      expect(
        patchedModules(),
        contains(equals({'id': 'guide', 'side': 'left', 'share': 45})),
      );

      await place(tester, KioskModule.notices, 'Vpravo', 'Vypnuto');
      expect(lastPatch(), {
        'kiosk_panels': patched(
          KioskPanels.defaults.withSide(KioskModule.notices, PanelSide.off),
        ),
      });
      expect(
        patchedModules(),
        contains(equals({'id': 'notices', 'side': 'off', 'share': 40})),
      );
    });

    testWidgets('a placed module\'s share: 5–95 %, the PATCH is the whole '
        'layout', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await type(tester, share(KioskModule.notices), '96');
      expect(find.text('Zadej číslo od 5 do 95.'), findsOneWidget);
      await type(tester, share(KioskModule.notices), '4');
      expect(find.text('Zadej číslo od 5 do 95.'), findsOneWidget);
      expect(patches(), 0);

      await type(tester, share(KioskModule.notices), '30');
      expect(lastPatch(), {
        'kiosk_panels': patched(
          KioskPanels.defaults.withShare(KioskModule.notices, 30),
        ),
      });
      expect(
        patchedModules(),
        contains(equals({'id': 'notices', 'side': 'right', 'share': 30})),
      );
    });

    testWidgets('↑↓ move a module among the placed ones of its panel: the '
        'first cannot go up, the last cannot go down', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(arrow(tester, KioskModule.notices, Icons.arrow_upward).onPressed,
          isNull);
      expect(
          arrow(tester, KioskModule.notices, Icons.arrow_downward).onPressed,
          isNotNull);
      expect(arrow(tester, KioskModule.matches, Icons.arrow_upward).onPressed,
          isNotNull);
      expect(
          arrow(tester, KioskModule.matches, Icons.arrow_downward).onPressed,
          isNull);

      final up =
          inRow(moduleRow(KioskModule.matches), find.byTooltip('Posunout výš'));
      await tester.ensureVisible(up);
      await tester.tap(up);
      await tester.pumpAndSettle();
      expect(lastPatch(), {
        'kiosk_panels': patched(
          KioskPanels.defaults.moved(KioskModule.matches, -1),
        ),
      });
      // The matches now come first on the right.
      expect(
        [
          for (final m in patchedModules().cast<Map>())
            if (m['side'] == 'right') m['id'],
        ],
        ['matches', 'notices'],
      );

      await tester.tap(
        inRow(moduleRow(KioskModule.notices), find.byTooltip('Posunout níž')),
      );
      await tester.pumpAndSettle();
      expect(lastPatch(), {
        'kiosk_panels': patched(
          KioskPanels.defaults.moved(KioskModule.notices, 1),
        ),
      });
    });

    testWidgets('modules on both sides: both panels\' rows, left first; the '
        'width 1–13 and the start PATCH the whole layout; the sum per '
        'panel', (tester) async {
      tall(tester);
      final both = KioskPanels.defaults
          .withSide(KioskModule.guide, PanelSide.left)
          .withSide(KioskModule.week, PanelSide.left);
      await tester.pumpWidget(app(settings: laid(both)));
      await tester.pumpAndSettle();

      double top(Finder f) => tester.getTopLeft(f).dy;
      expect(inRow(panelRow(PanelSide.left), find.text('Levý panel')),
          findsOneWidget);
      expect(inRow(panelRow(PanelSide.right), find.text('Pravý panel')),
          findsOneWidget);
      expect(top(panelRow(PanelSide.left)),
          lessThan(top(panelRow(PanelSide.right))));
      expect(find.text('Vlevo 100 % · Vpravo 100 %'), findsOneWidget);

      await type(tester, width(PanelSide.left), '14');
      expect(find.text('Zadej číslo od 1 do 13.'), findsOneWidget);
      await type(tester, width(PanelSide.left), '0');
      expect(patches(), 0);
      await type(tester, width(PanelSide.left), '3');
      expect(lastPatch(), {
        'kiosk_panels': patched(both.withPanel(PanelSide.left, days: 3)),
      });

      final open =
          inRow(panelRow(PanelSide.left), find.byType(SwitchListTile));
      await tester.ensureVisible(open);
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(lastPatch(), {
        'kiosk_panels': patched(both.withPanel(PanelSide.left, open: true)),
      });
    });

    testWidgets('the match list follows the matches to either panel; a sum '
        'other than 100 shows as it is; alone in its panel a module has '
        'nowhere to move', (tester) async {
      tall(tester);
      await tester.pumpWidget(app(
        settings: laid(
          KioskPanels.defaults.withSide(KioskModule.matches, PanelSide.left),
        ),
      ));
      await tester.pumpAndSettle();

      expect(panelRow(PanelSide.left), findsOneWidget);
      expect(panelRow(PanelSide.right), findsOneWidget);
      expect(find.text('Vlevo 60 % · Vpravo 40 %'), findsOneWidget);
      expect(
        inSection(
          'Zápasy',
          find.widgetWithText(SwitchListTile, 'I budoucí zápasy'),
        ),
        findsOneWidget,
      );
      expect(
        inSection(
          'Hraný zápas',
          find.widgetWithText(SwitchListTile, 'Hraný zápas přes celý panel'),
        ),
        findsOneWidget,
      );
      expect(arrow(tester, KioskModule.matches, Icons.arrow_upward).onPressed,
          isNull);
      expect(
          arrow(tester, KioskModule.matches, Icons.arrow_downward).onPressed,
          isNull);
    });

    testWidgets('no module in a panel: no panel rows and no sums; the match '
        'list\'s and the live match\'s sections go with the matches', (
      tester,
    ) async {
      tall(tester);
      await tester.pumpWidget(app(
        settings: laid(
          KioskPanels.defaults
              .withSide(KioskModule.notices, PanelSide.off)
              .withSide(KioskModule.matches, PanelSide.off),
        ),
      ));
      await tester.pumpAndSettle();

      expect(panelRow(PanelSide.left), findsNothing);
      expect(panelRow(PanelSide.right), findsNothing);
      expect(find.textContaining(RegExp(r'^(Vlevo|Vpravo) \d+ %')),
          findsNothing);
      expect(find.text('Podíly se přepočítají na celou výšku panelu.'),
          findsNothing);
      for (final m in KioskModule.values) {
        expect(inRow(moduleRow(m), find.text('Vypnuto')), findsOneWidget,
            reason: m.name);
      }
      expect(section('Zápasy'), findsNothing);
      expect(section('Hraný zápas'), findsNothing);
      expect(find.widgetWithText(SwitchListTile, 'I budoucí zápasy'),
          findsNothing);
      expect(
        find.widgetWithText(SwitchListTile, 'Hraný zápas přes celý panel'),
        findsNothing,
      );
      expect(section('Nástěnka'), findsOneWidget);
      expect(section('Služby na kantýně'), findsOneWidget);
    });

    testWidgets('„Zápasy“: the list\'s options of the old side panel, in '
        'order, each PATCHing its own column', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(
        inSection('Zápasy', find.textContaining('Seznam zápasů kuželny')),
        findsOneWidget,
      );
      double top(Finder f) => tester.getTopLeft(f).dy;
      final options = [
        find.widgetWithText(SwitchListTile, 'I budoucí zápasy'),
        find.widgetWithText(SwitchListTile, 'Seznam sleduje tabuli'),
        find.widgetWithText(TextField, 'Odehrané zápasy: týdnů zpět'),
        find.widgetWithText(TextField, 'Budoucí zápasy: týdnů dopředu'),
      ];
      for (var i = 0; i < options.length; i++) {
        expect(inSection('Zápasy', options[i]), findsOneWidget,
            reason: 'option $i');
        if (i > 0) {
          expect(top(options[i - 1]), lessThan(top(options[i])),
              reason: 'option $i');
        }
      }
      await tester.ensureVisible(options[1]);
      await tester.tap(options[1]);
      await tester.pumpAndSettle();
      expect(lastPatch(), {'kiosk_follow_board': false});
    });

    testWidgets('a module of a newer app is not listed and goes back '
        'unchanged with every PATCH', (tester) async {
      tall(tester);
      await tester.pumpWidget(app(
        settings: laid(
          KioskPanels.fromJson({
            'left': {'days': 2, 'open': false},
            'right': {'days': 2, 'open': false},
            'modules': [
              {'id': 'duty', 'side': 'off', 'share': 30},
              {'id': 'notices', 'side': 'right', 'share': 40},
              {'id': 'matches', 'side': 'right', 'share': 60},
              {'id': 'guide', 'side': 'off', 'share': 45},
              {'id': 'week', 'side': 'off', 'share': 55},
              {'id': 'radar', 'side': 'left', 'share': 50},
            ],
          }),
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        inSection('Panely', find.byType(DropdownButtonFormField<PanelSide>)),
        findsNWidgets(5),
      );
      // Nothing this app shows is on the left: no row for that panel.
      expect(panelRow(PanelSide.left), findsNothing);

      await type(tester, width(PanelSide.right), '3');
      expect(
        patchedModules(),
        contains(equals({'id': 'radar', 'side': 'left', 'share': 50})),
      );
    });

    testWidgets('on a phone a placed module\'s share and arrows go under its '
        'name and its list', (tester) async {
      // Narrower than the table's one-line width (520 inside the page's
      // padding) — and wide enough for the other lists in the test font.
      tester.view.physicalSize = const Size(500, 8000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      final row = moduleRow(KioskModule.notices);
      await tester.ensureVisible(row);
      final list =
          inRow(row, find.byType(DropdownButtonFormField<PanelSide>));
      expect(
        tester.getTopLeft(share(KioskModule.notices)).dy,
        greaterThan(tester.getBottomLeft(list).dy),
      );
      expect(inRow(row, find.byTooltip('Posunout níž')), findsOneWidget);
      // No head on two-line rows: each control says what it is.
      expect(find.byKey(const ValueKey('kiosk-modules-header')), findsNothing);
      expect(inRow(row, find.text('Panel')), findsOneWidget);
    });
  });

  testWidgets('the performance options PATCH their own columns: the breathing '
      'on by default, the low resolution off', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;

    final breathing =
        find.widgetWithText(SwitchListTile, 'Opakující se animace');
    await tester.ensureVisible(breathing);
    await tester.tap(breathing);
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_animations': false});

    final lowRes =
        find.widgetWithText(SwitchListTile, 'Nižší rozlišení (jen web)');
    await tester.ensureVisible(lowRes);
    await tester.tap(lowRes);
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_low_res': true});
  });

  testWidgets('the stream options: the switch PATCHes kiosk_stream, the '
      'corner, the width and the windows at once PATCH their own columns — '
      'all of them shown with the switch off too, a visitor opens streams '
      'regardless', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;

    final stream = find.widgetWithText(
      SwitchListTile,
      'Živý přenos se otevře sám',
    );
    await tester.ensureVisible(stream);
    await tester.tap(stream);
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_stream': true});

    await tester.ensureVisible(find.text('Kde se okno objeví'));
    await tester.tap(find.text('Vlevo dole'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vpravo nahoře').last);
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_stream_corner': 'tr'});

    final width = find.widgetWithText(TextField, 'Šířka okna');
    await tester.ensureVisible(width);
    await tester.enterText(width, '50');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_stream_width': 50});

    final windows = find.widgetWithText(TextField, 'Oken najednou');
    await tester.ensureVisible(windows);
    await tester.enterText(windows, '3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_stream_max': 3});
  });

  testWidgets('paging through the Zápis: the bar by default, one of three, '
      'under its size; a choice PATCHes its own column (0079)', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final paging = find.widgetWithText(
      DropdownButtonFormField<KioskZapisNav>,
      'Listování v zápisu',
    );
    expect(find.descendant(of: paging, matching: find.text('Lišta nad zápisem')),
        findsOneWidget);
    expect(
      tester.getTopLeft(paging).dy,
      greaterThan(tester.getTopLeft(find.text('Velikost zápisu')).dy),
    );
    await tester.ensureVisible(paging);
    await tester.tap(paging);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Šipky po stranách').last);
    await tester.pumpAndSettle();
    final patch = jsonDecode(
      requests.lastWhere((r) => r.method == 'PATCH').body,
    ) as Map<String, dynamic>;
    expect(patch, {'kiosk_zapis_nav': 'sides'});
  });

  testWidgets('the streams\' master switch comes first in its section and '
      'PATCHes kiosk_stream_enabled', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final master = find.widgetWithText(SwitchListTile, 'Stream na kiosku');
    await tester.ensureVisible(master);
    expect(
      find.text('Vypnuto = u zápasů žádné ▶ a žádné okno se streamem.'),
      findsOneWidget,
    );
    // Above the section's other options.
    expect(
      tester.getTopLeft(master).dy,
      lessThan(
        tester
            .getTopLeft(
              find.widgetWithText(
                SwitchListTile,
                'Živý přenos se otevře sám',
              ),
            )
            .dy,
      ),
    );
    await tester.tap(master);
    await tester.pumpAndSettle();
    expect(jsonDecode(requests.lastWhere((r) => r.method == 'PATCH').body),
        {'kiosk_stream_enabled': false});
  });

  testWidgets('with the streams off the section has only its master switch',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(app(
      settings: const ScheduleSettings(
        laneCount: 4,
        trainingWeekdays: {1, 2, 4},
        bookingHorizonDays: 14,
        maxActiveReservations: 3,
        kioskStreamEnabled: false,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Stream zápasu'), findsOneWidget);
    expect(
      find.widgetWithText(SwitchListTile, 'Stream na kiosku'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(SwitchListTile, 'Živý přenos se otevře sám'),
      findsNothing,
    );
    expect(find.text('Kde se okno objeví'), findsNothing);
    expect(find.widgetWithText(TextField, 'Šířka okna'), findsNothing);
    expect(find.widgetWithText(TextField, 'Oken najednou'), findsNothing);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Stream na kiosku'));
    await tester.pumpAndSettle();
    expect(jsonDecode(requests.lastWhere((r) => r.method == 'PATCH').body),
        {'kiosk_stream_enabled': true});
  });

  /// Types [text] into the number field [label] and presses Enter.
  Future<void> enter(WidgetTester tester, String label, String text) async {
    final field = find.widgetWithText(TextField, label);
    await tester.ensureVisible(field);
    await tester.enterText(field, text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  group('canteen duty (0073)', () {
    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;

    testWidgets('in its section only the band in the calendar, off by '
        'default, PATCHing its own column; the header\'s module is the '
        'Záhlaví table\'s, the card in a panel the Panely table\'s', (
      tester,
    ) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(inSection('Služby na kantýně', find.text('Služby na kantýně')),
          findsOneWidget);
      expect(
        inSection(
          'Služby na kantýně',
          find.text(
            'Kdo právě slouží na kantýně a kdo přijde na řadu — podle plánu '
            've Správě → Služby. Do záhlaví dáš službu v Záhlaví, kartu do '
            'panelu v Panelech (výš).',
          ),
        ),
        findsOneWidget,
      );
      expect(
        inSection(
          'Služby na kantýně',
          find.widgetWithText(SwitchListTile, 'V záhlaví'),
        ),
        findsNothing,
      );
      expect(
        find.text('Pod hodinami „Služba: …“ s dnešní službou; ťuk ukáže '
            'plán.'),
        findsNothing,
      );
      final board = inSection(
        'Služby na kantýně',
        find.widgetWithText(SwitchListTile, 'V kalendáři'),
      );
      await tester.ensureVisible(board);
      expect(tester.widget<SwitchListTile>(board).value, isFalse);
      await tester.tap(board);
      await tester.pumpAndSettle();
      expect(lastPatch(), {'kiosk_duty_board': true});
      expect(find.text('Pás se jmény přes dny služby v hlavičkách dnů '
          'tabule.'), findsOneWidget);
      // The header's module and the card are rows of the tables.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('kiosk-header-module:duty')),
          matching: find.text('Služba na kantýně'),
        ),
        findsOneWidget,
      );
      expect(find.widgetWithText(SwitchListTile, 'V panelu'), findsNothing);
      expect(find.widgetWithText(TextField, 'Podíl karty v panelu'),
          findsNothing);
      expect(inSection('Panely', find.text('Služba na kantýně')),
          findsOneWidget);
      // Without the band no place for it.
      expect(find.text('Kde je pás'), findsNothing);
    });

    testWidgets('with the band in the calendar, where it runs is picked from '
        'a list right under its switch: between the date and the matches by '
        'default; PATCHes kiosk_duty_band_position', (tester) async {
      tall(tester);
      await tester.pumpWidget(app(
        settings: const ScheduleSettings(
          laneCount: 4,
          trainingWeekdays: {1},
          bookingHorizonDays: 14,
          maxActiveReservations: 3,
          kioskDutyBoard: true,
          tenantId: 't',
        ),
      ));
      await tester.pumpAndSettle();

      final field = find.byType(DropdownButtonFormField<KioskDutyBandPosition>);
      expect(field, findsOneWidget);
      expect(
        find.descendant(of: field, matching: find.text('Kde je pás')),
        findsOneWidget,
      );
      double top(Finder f) => tester.getTopLeft(f).dy;
      expect(
        top(field),
        greaterThan(top(find.widgetWithText(SwitchListTile, 'V kalendáři'))),
      );
      expect(inSection('Služby na kantýně', field), findsOneWidget);

      await tester.ensureVisible(field);
      await tester.tap(find.text('Mezi datem a zápasy'));
      await tester.pumpAndSettle();
      expect(find.text('Nad datem'), findsOneWidget);
      expect(find.text('Dole pod zápasy'), findsOneWidget);
      await tester.tap(find.text('Dole pod zápasy').last);
      await tester.pumpAndSettle();
      expect(lastPatch(), {'kiosk_duty_band_position': 'bottom'});

      await tester.tap(find.text('Dole pod zápasy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nad datem').last);
      await tester.pumpAndSettle();
      expect(lastPatch(), {'kiosk_duty_band_position': 'top'});
    });

    testWidgets('the admin\'s place for the band shows chosen', (
      tester,
    ) async {
      tall(tester);
      await tester.pumpWidget(app(
        settings: const ScheduleSettings(
          laneCount: 4,
          trainingWeekdays: {1},
          bookingHorizonDays: 14,
          maxActiveReservations: 3,
          kioskDutyBoard: true,
          kioskDutyBandPosition: KioskDutyBandPosition.top,
          tenantId: 't',
        ),
      ));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(DropdownButtonFormField<KioskDutyBandPosition>),
          matching: find.text('Nad datem'),
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('the numbers are typed in: each PATCHes its own column on '
      'Enter', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;

    // The defaults are in the fields: 60 s, 2 weeks back.
    String shown(String label) =>
        tester.widget<TextField>(find.widgetWithText(TextField, label))
            .controller!.text;
    expect(shown('Doba nečinnosti'), '60');
    expect(shown('Odehrané zápasy: týdnů zpět'), '2');

    await enter(tester, 'Doba nečinnosti', '300');
    expect(lastPatch(), {'kiosk_idle_seconds': 300});
    await enter(tester, 'Střídání oznamů', '20');
    expect(lastPatch(), {'kiosk_notices_rotation_seconds': 20});
    await enter(tester, 'Odehrané zápasy: týdnů zpět', '0');
    expect(lastPatch(), {'kiosk_weeks_back': 0});
    await enter(tester, 'Budoucí zápasy: týdnů dopředu', '3');
    expect(lastPatch(), {'kiosk_weeks_ahead': 3});
    await enter(tester, 'Kontrola výsledků', '120');
    expect(lastPatch(), {'kiosk_live_refresh_seconds': 120});
    await enter(tester, 'Střídání hraných zápasů', '30');
    expect(lastPatch(), {'kiosk_live_rotation_seconds': 30});
    await enter(tester, 'Velikost zápisu', '100');
    expect(lastPatch(), {'kiosk_zapis_percent': 100});
  });

  testWidgets('a number out of its range is refused: the field says the '
      'range and nothing is written; the same number writes nothing either',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    int patches() => requests.where((r) => r.method == 'PATCH').length;

    await enter(tester, 'Velikost zápisu', '120');
    expect(find.text('Zadej číslo od 50 do 100.'), findsOneWidget);
    expect(patches(), 0);
    await enter(tester, 'Doba nečinnosti', '');
    expect(find.text('Zadej číslo od 15 do 600.'), findsOneWidget);
    expect(patches(), 0);
    // The default again: no write, and the error goes away.
    await enter(tester, 'Doba nečinnosti', '60');
    expect(find.text('Zadej číslo od 15 do 600.'), findsNothing);
    expect(patches(), 0);
  });

  testWidgets('the screen block: dark mode, then the idle time and the Zápis '
      'size, then the day on the screen and the days on the screen', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    double top(Finder f) => tester.getTopLeft(f).dy;
    final order = [
      top(find.text('Tmavý režim')),
      top(find.widgetWithText(TextField, 'Doba nečinnosti')),
      top(find.widgetWithText(TextField, 'Velikost zápisu')),
      top(find.text('Celý den na obrazovku')),
      top(find.widgetWithText(TextField, 'Dní na obrazovce')),
      top(find.text('Posun tabule do minulosti')),
      top(section('Záhlaví')),
    ];
    for (var i = 1; i < order.length; i++) {
      expect(order[i - 1], lessThan(order[i]), reason: 'option $i');
    }
    // The Zápis size moved out of the live match's block.
    expect(find.widgetWithText(TextField, 'Velikost zápisu'), findsOneWidget);
  });

  testWidgets('the bands\' font size: 8–24 px, the app\'s 10 by default, '
      'PATCHes its own column', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final field = find.widgetWithText(TextField, 'Písmo zápasů a pronájmů');
    await tester.ensureVisible(field);
    expect(tester.widget<TextField>(field).controller!.text, '10');
    await tester.enterText(field, '16');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      jsonDecode(requests.lastWhere((r) => r.method == 'PATCH').body),
      {'kiosk_band_font_size': 16},
    );
  });

  for (final (label, before, after, column) in [
    ('Písmo upozornění', '22', 28, 'kiosk_warning_font_size'),
    ('Šířka přehledu zápasů dne', '560', 800, 'kiosk_day_matches_width'),
  ]) {
    testWidgets('„$label“ (0075) shows $before by default and PATCHes its '
        'own column', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final field = find.widgetWithText(TextField, label);
      await tester.ensureVisible(field);
      expect(tester.widget<TextField>(field).controller!.text, before);
      await tester.enterText(field, '$after');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
        jsonDecode(requests.lastWhere((r) => r.method == 'PATCH').body),
        {column: after},
      );
    });
  }

  group('the note when booking (0070)', () {
    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;
    Finder field() => find.widgetWithText(TextField, 'Text upozornění');
    String fieldText(WidgetTester tester) =>
        tester.widget<TextField>(field()).controller!.text;

    testWidgets('none: first in the screen block, „Přidat…“ starts from the '
        'default text, blank cannot be saved, „Výchozí text“ puts it back', (
      tester,
    ) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(
        find.text('Žádné. Upozornění na první stránce výběru hráče na kiosku.'),
        findsOneWidget,
      );
      expect(find.byTooltip('Odstranit upozornění při rezervaci'), findsNothing);
      double top(Finder f) => tester.getTopLeft(f).dy;
      expect(
        top(find.text('Upozornění při rezervaci')),
        greaterThan(top(find.text('Obrazovka kiosku'))),
      );
      expect(
        top(find.text('Upozornění při rezervaci')),
        lessThan(top(find.text('Tmavý režim'))),
      );

      await tester.tap(inTile('Upozornění při rezervaci', 'Přidat…'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Upozornění při rezervaci'),
        ),
        findsOneWidget,
      );
      expect(fieldText(tester), ScheduleSettings.defaultPickerNote);
      final restore = find.ancestor(
        of: find.text('Výchozí text'),
        matching: find.bySubtype<TextButton>(),
      );
      final save = find.widgetWithText(FilledButton, 'Uložit');
      // Already the default: nothing to put back.
      expect(tester.widget<TextButton>(restore).onPressed, isNull);
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);

      await tester.enterText(field(), '   ');
      await tester.pump();
      expect(tester.widget<FilledButton>(save).onPressed, isNull);

      await tester.tap(restore);
      await tester.pump();
      expect(fieldText(tester), ScheduleSettings.defaultPickerNote);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(lastPatch(), {
        'kiosk_picker_note': ScheduleSettings.defaultPickerNote,
      });
    });

    testWidgets('a note set: shown, „Upravit…“ starts from it and saves it '
        'trimmed, „Zrušit“ writes nothing, the bin removes it', (
      tester,
    ) async {
      tall(tester);
      await tester.pumpWidget(
        app(
          settings: const ScheduleSettings(
            laneCount: 4,
            trainingWeekdays: {1, 2, 4},
            bookingHorizonDays: 14,
            maxActiveReservations: 3,
            kioskPickerNote: 'Zrušit jde jen v aplikaci.',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Zrušit jde jen v aplikaci.'), findsOneWidget);

      await tester.tap(inTile('Upozornění při rezervaci', 'Upravit…'));
      await tester.pumpAndSettle();
      expect(fieldText(tester), 'Zrušit jde jen v aplikaci.');
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();
      expect(requests.where((r) => r.method == 'PATCH'), isEmpty);

      await tester.tap(inTile('Upozornění při rezervaci', 'Upravit…'));
      await tester.pumpAndSettle();
      await tester.enterText(field(), '  Zrušit jde v aplikaci i na webu. ');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Uložit'));
      await tester.pumpAndSettle();
      expect(lastPatch(), {
        'kiosk_picker_note': 'Zrušit jde v aplikaci i na webu.',
      });

      await tester.tap(find.byTooltip('Odstranit upozornění při rezervaci'));
      await tester.pumpAndSettle();
      expect(lastPatch(), {'kiosk_picker_note': null});
    });

    testWidgets('how the picker starts (0076): by letters by default, right '
        'under the note; PATCHes kiosk_picker_mode', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      final dropdown = find.byType(DropdownButtonFormField<KioskPickerMode>);
      expect(
        find.descendant(of: dropdown, matching: find.text('Výběr hráče')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dropdown, matching: find.text('Podle písmen')),
        findsOneWidget,
      );
      double top(Finder f) => tester.getTopLeft(f).dy;
      expect(
        top(dropdown),
        greaterThan(top(find.text('Upozornění při rezervaci'))),
      );
      expect(top(dropdown), lessThan(top(find.text('Písmo upozornění'))));

      await tester.ensureVisible(dropdown);
      await tester.tap(find.text('Podle písmen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Podle oddílu i písmen').last);
      await tester.pumpAndSettle();
      expect(lastPatch(), {'kiosk_picker_mode': 'both'});

      await tester.tap(find.text('Podle oddílu i písmen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Podle oddílu').last);
      await tester.pumpAndSettle();
      expect(lastPatch(), {'kiosk_picker_mode': 'clubs'});
    });

    testWidgets('the admin\'s picker mode shows chosen', (tester) async {
      tall(tester);
      await tester.pumpWidget(app(
        settings: const ScheduleSettings(
          laneCount: 4,
          trainingWeekdays: {1},
          bookingHorizonDays: 14,
          maxActiveReservations: 3,
          kioskPickerMode: KioskPickerMode.clubs,
          tenantId: 't',
        ),
      ));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(DropdownButtonFormField<KioskPickerMode>),
          matching: find.text('Podle oddílu'),
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('the days on the screen: 2–14, a week by default', (
    tester,
  ) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;
    String shown(String label) =>
        tester.widget<TextField>(find.widgetWithText(TextField, label))
            .controller!.text;
    expect(shown('Dní na obrazovce'), '7');

    await enter(tester, 'Dní na obrazovce', '1');
    expect(find.text('Zadej číslo od 2 do 14.'), findsOneWidget);
    expect(requests.where((r) => r.method == 'PATCH'), isEmpty);
    await enter(tester, 'Dní na obrazovce', '5');
    expect(lastPatch(), {'kiosk_visible_days': 5});
  });

  testWidgets('the font size of the board shows only while the day scrolls', (
    tester,
  ) async {
    tall(tester);
    // Fit day on (the default): the font follows the rows, no field.
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Velikost písma na tabuli'), findsNothing);
    await tester.pumpWidget(const SizedBox());

    await tester.pumpWidget(app(
      settings: const ScheduleSettings(
        laneCount: 4,
        trainingWeekdays: {1},
        bookingHorizonDays: 14,
        maxActiveReservations: 3,
        kioskFitDay: false,
        tenantId: 't',
      ),
    ));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Velikost písma na tabuli'))
          .controller!
          .text,
      '11',
    );
    await enter(tester, 'Velikost písma na tabuli', '16');
    expect(jsonDecode(requests.lastWhere((r) => r.method == 'PATCH').body),
        {'kiosk_font_size': 16});
  });

  testWidgets('leaving a number field writes it too', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byKey(const ValueKey('kiosk-panel:right')),
      matching: find.widgetWithText(TextField, 'Šířka'),
    );
    await tester.ensureVisible(field);
    await tester.enterText(field, '3');
    // Focus moves on to another field: the first one commits — the whole
    // layout, with the right panel three days wide.
    await tester.tap(find.widgetWithText(TextField, 'Doba nečinnosti'));
    await tester.pumpAndSettle();
    expect(jsonDecode(requests.lastWhere((r) => r.method == 'PATCH').body), {
      'kiosk_panels': {
        'left': {'days': 2, 'open': false},
        'right': {'days': 3, 'open': false},
        'modules': [
          {'id': 'duty', 'side': 'off', 'share': 30},
          {'id': 'notices', 'side': 'right', 'share': 40},
          {'id': 'matches', 'side': 'right', 'share': 60},
          {'id': 'guide', 'side': 'off', 'share': 45},
          {'id': 'week', 'side': 'off', 'share': 55},
        ],
      },
    });
  });

  testWidgets('the options come in sections: screen, header, panels, '
      'notices, canteen duty, matches, live match, stream, performance, then '
      'the address and the accounts', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    double top(Finder f) => tester.getTopLeft(f).dy;
    const sections = [
      'Obrazovka kiosku',
      'Záhlaví',
      'Panely',
      'Nástěnka',
      'Služby na kantýně',
      'Zápasy',
      'Hraný zápas',
      'Stream zápasu',
      'Optimalizace výkonu',
    ];
    for (final title in sections) {
      expect(inSection(title, find.text(title)), findsOneWidget,
          reason: title);
    }
    final order = [
      for (final title in sections) top(section(title)),
      top(find.text('Adresa pro tablet')),
      top(find.text('Kioskové účty')),
    ];
    for (var i = 1; i < order.length; i++) {
      expect(order[i - 1], lessThan(order[i]), reason: 'section $i');
    }
    expect(find.text('Postranní panel'), findsNothing);
    expect(section('Stavový řádek'), findsNothing);
  });

  testWidgets('the live match\'s drawing is chosen from a list', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;
    await tester.ensureVisible(find.text('Zobrazení hraného zápasu'));
    // The default: the cards. Zápis is the app's own layout, never offered.
    await tester.tap(find.text('Podrobné — karty soubojů').first);
    await tester.pumpAndSettle();
    expect(find.text('Kompaktní — bez posouvání'), findsOneWidget);
    expect(find.text('Tabulka — souboj na řádek'), findsOneWidget);
    expect(find.text('Zápis'), findsNothing);
    await tester.tap(find.text('Tabulka — souboj na řádek').last);
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_live_layout': 'table'});
  });

  testWidgets('the ranges say they are only the default', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.textContaining('Jen výchozí rozsah'), findsNWidgets(2));
    // Each names the kiosk's button for its own direction.
    expect(find.textContaining('(„Zobrazit předchozí“)'), findsOneWidget);
    expect(find.textContaining('(„Zobrazit další“)'), findsOneWidget);
  });

  testWidgets('a rotation shows only with what it rotates', (tester) async {
    tall(tester);
    await tester.pumpWidget(app(
      settings: ScheduleSettings(
        laneCount: 4,
        trainingWeekdays: const {1},
        bookingHorizonDays: 14,
        maxActiveReservations: 3,
        kioskHeader: KioskHeader.defaults.withSide(
          KioskHeaderModule.notices,
          PanelSide.off,
        ),
        kioskPanels: KioskPanels.defaults.withSide(
          KioskModule.notices,
          PanelSide.off,
        ),
        kioskLiveMode: false,
        tenantId: 't',
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Střídání oznamů'), findsNothing);
    expect(find.text('Střídání hraných zápasů'), findsNothing);
    expect(find.text('Kontrola výsledků'), findsNothing);
    // The Zápis size is not the live match's alone: a finished match in the
    // list opens one too.
    expect(find.text('Velikost zápisu'), findsOneWidget);
  });

  testWidgets('the look back into the past is an on/off and a number of days',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;

    // Off by default: no number to type.
    expect(find.text('Kolik dní zpět'), findsNothing);
    await tester.tap(
        find.widgetWithText(SwitchListTile, 'Posun tabule do minulosti'));
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_past_days': 7});

    // On: the number shows and is typed in. (A fresh scope: a ProviderScope
    // keeps the overrides it was born with.)
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(
      settings: const ScheduleSettings(
        laneCount: 4,
        trainingWeekdays: {1},
        bookingHorizonDays: 14,
        maxActiveReservations: 3,
        kioskPastDays: 7,
        tenantId: 't',
      ),
    ));
    await tester.pumpAndSettle();
    await enter(tester, 'Kolik dní zpět', '14');
    expect(lastPatch(), {'kiosk_past_days': 14});
  });

  testWidgets('the upcoming matches and the live match have their switches',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;

    await tester.tap(find.widgetWithText(SwitchListTile, 'I budoucí zápasy'));
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_show_upcoming': false});

    await tester.tap(find.widgetWithText(
        SwitchListTile, 'Hraný zápas přes celý panel'));
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_live_mode': false});
  });

  testWidgets('the texts speak of two panels', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    for (final text in [
      // Doba nečinnosti.
      'Po tolika sekundách bez dotyku kiosk zapomene vybraného hráče, zavře '
          'okna i zápis, vrátí tabuli na dnešek a panely do výchozího stavu.',
      // Dní na obrazovce.
      'Kolik dní (sloupců) je na celé obrazovce najednou; další jsou o kus '
          'vedle. Rozbalené panely z nich zakryjí tolik, kolik je jejich '
          'šířka.',
      // Kde se okno objeví.
      'Okno překryje panel na své straně; vyber roh na straně bez panelu. '
          'Další okna do dalších rohů — nejdřív na stejné straně.',
      // Opakující se animace.
      'Tlačítka panelů se každé čtyři sekundy rozzáří a ikona živého '
          'přenosu pulzuje; při tom se překresluje celá obrazovka, i když se '
          'kiosku nikdo nedotýká. Vypnuto = obojí je v klidu.',
      // Hraný zápas přes celý panel.
      'Souboje hraného zápasu zaberou celý panel se zápasy a ten zůstane '
          'rozbalený — i když ho návštěvník zavře, po době nečinnosti se '
          'rozbalí znovu. Vypnuto = hraný zápas je jen řádek v seznamu.',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    // The duty's module is placed in the Záhlaví table, its card in the
    // Panely one.
    expect(
      inSection(
        'Služby na kantýně',
        find.text(
          'Kdo právě slouží na kantýně a kdo přijde na řadu — podle plánu ve '
          'Správě → Služby. Do záhlaví dáš službu v Záhlaví, kartu do panelu '
          'v Panelech (výš).',
        ),
      ),
      findsOneWidget,
    );
    // Nothing says the panel is on the right, or that there is one button.
    expect(find.textContaining('Panel je vpravo'), findsNothing);
    expect(find.textContaining('Tlačítko panelu'), findsNothing);
    expect(find.textContaining('a panel do výchozího stavu'), findsNothing);
  });
}
