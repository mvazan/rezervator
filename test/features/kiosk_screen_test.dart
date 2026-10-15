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
    tester.view.physicalSize = const Size(800, 5600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget app({
    List<Profile> roster = const [admin],
    Future<String> Function(String)? resetPassword,
    ScheduleSettings? settings,
    bool? panelEnabled,
    Venue? alleyVenue,
    http.Client? openMeteo,
  }) {
    final shown = settings ??
        (panelEnabled == null
            ? defaults0
            : ScheduleSettings(
                laneCount: 4,
                trainingWeekdays: const {1, 2, 4},
                bookingHorizonDays: 14,
                maxActiveReservations: 3,
                kioskPanelEnabled: panelEnabled,
              ));
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

  group('status line', () {
    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;
    final sokol = Venue(
      id: 'v1',
      slug: 'tj-sokol-brno-iv',
      name: 'TJ Sokol Brno IV',
      address: 'Štolcova 551/8, 61800 Brno',
      lat: 49.1891783,
      lng: 16.6354503,
      fetchedAt: DateTime(2026, 9, 1),
    );
    const weatherOn = ScheduleSettings(
      laneCount: 4,
      trainingWeekdays: {1, 2, 4},
      bookingHorizonDays: 14,
      maxActiveReservations: 3,
      kioskWeather: true,
    );

    testWidgets('switching the weather on takes the alley\'s venue as its '
        'place when none was picked', (tester) async {
      tall(tester);
      await tester.pumpWidget(app(alleyVenue: sokol));
      await tester.pumpAndSettle();
      expect(find.text('Místo pro počasí'), findsNothing);

      await tester.tap(find.widgetWithText(SwitchListTile, 'Počasí'));
      await tester.pumpAndSettle();
      expect(lastPatch(), {
        'kiosk_weather': true,
        'kiosk_weather_place': 'TJ Sokol Brno IV, Štolcova 551/8, 61800 Brno',
        'kiosk_weather_lat': 49.1891783,
        'kiosk_weather_lon': 16.6354503,
      });
    });

    testWidgets('switching the weather on again keeps the place the admin '
        'picked — the venue does not overwrite it', (tester) async {
      tall(tester);
      await tester.pumpWidget(
        app(
          alleyVenue: sokol,
          settings: const ScheduleSettings(
            laneCount: 4,
            trainingWeekdays: {1, 2, 4},
            bookingHorizonDays: 14,
            maxActiveReservations: 3,
            kioskWeatherPlace: 'Brno, Jihomoravský',
            kioskWeatherLat: 49.19522,
            kioskWeatherLon: 16.60796,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, 'Počasí'));
      await tester.pumpAndSettle();
      expect(lastPatch(), {'kiosk_weather': true});
    });

    testWidgets('without a known venue the switch only turns it on; the row '
        'says the place is missing', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, 'Počasí'));
      await tester.pumpAndSettle();
      expect(lastPatch(), {'kiosk_weather': true});
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
        app(settings: weatherOn, alleyVenue: sokol, openMeteo: openMeteo),
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
          settings: weatherOn,
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
          settings: weatherOn,
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

    testWidgets('the name day switch PATCHes kiosk_nameday', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final nameday = find.widgetWithText(SwitchListTile, 'Svátek');
      await tester.ensureVisible(nameday);
      await tester.tap(nameday);
      await tester.pumpAndSettle();
      expect(lastPatch(), {'kiosk_nameday': true});
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

  testWidgets('the panel options PATCH their own columns', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;

    await tester.ensureVisible(find.text('Kde se oznamy zobrazí'));
    await tester.tap(find.text('V záhlaví i v panelu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jen v záhlaví').last);
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_notices_mode': 'header'});

    await tester.tap(find.widgetWithText(SwitchListTile, 'Zápasy v panelu'));
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_show_matches': false});

    await tester.tap(
        find.widgetWithText(SwitchListTile, 'Výchozně rozbalený'));
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_drawer_open': true});
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

  testWidgets('today\'s matches in the header: on by default, in the '
      'Stavový řádek section; the switch PATCHes its own column', (
    tester,
  ) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;

    final todays =
        find.widgetWithText(SwitchListTile, 'Dnešní zápasy v záhlaví');
    expect(tester.widget<SwitchListTile>(todays).value, isTrue);
    expect(
      tester.getTopLeft(todays).dy,
      greaterThan(tester.getTopLeft(find.text('Stavový řádek')).dy),
    );
    expect(
      tester.getTopLeft(todays).dy,
      lessThan(tester.getTopLeft(find.text('Nástěnka')).dy),
    );

    await tester.ensureVisible(todays);
    await tester.tap(todays);
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_todays_matches': false});
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

    testWidgets('three places, each its own switch, all off by default: '
        'each PATCHes its own column', (tester) async {
      tall(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.text('Služby na kantýně'), findsOneWidget);
      expect(
        find.textContaining('Správě → Služby. Každé místo se zapíná zvlášť.'),
        findsOneWidget,
      );
      for (final (title, column) in [
        ('V záhlaví', 'kiosk_duty_header'),
        ('V kalendáři', 'kiosk_duty_board'),
        ('V panelu', 'kiosk_duty_drawer'),
      ]) {
        final tile = find.widgetWithText(SwitchListTile, title);
        await tester.ensureVisible(tile);
        expect(tester.widget<SwitchListTile>(tile).value, isFalse,
            reason: title);
        await tester.tap(tile);
        await tester.pumpAndSettle();
        expect(lastPatch(), {column: true}, reason: title);
      }
      // What each place is.
      expect(find.text('Pod hodinami „Služba: …“ s dnešní službou; ťuk '
          'ukáže plán.'), findsOneWidget);
      expect(find.text('Pás se jmény přes dny služby v hlavičkách dnů '
          'tabule.'), findsOneWidget);
      expect(find.text('Karta se službou a plánem v postranním panelu.'),
          findsOneWidget);
      // Without the card there is no share of the drawer to set, without
      // the band no place for it.
      expect(find.widgetWithText(TextField, 'Podíl karty v panelu'),
          findsNothing);
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
      expect(
        top(field),
        lessThan(top(find.widgetWithText(SwitchListTile, 'V panelu'))),
      );

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

    testWidgets('with the card in the drawer its share shows: 30 % by '
        'default, 10–90, PATCHes kiosk_duty_share', (tester) async {
      tall(tester);
      await tester.pumpWidget(app(
        settings: const ScheduleSettings(
          laneCount: 4,
          trainingWeekdays: {1},
          bookingHorizonDays: 14,
          maxActiveReservations: 3,
          kioskDutyDrawer: true,
          tenantId: 't',
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, 'V panelu'),
        ).value,
        isTrue,
      );
      final share = find.widgetWithText(TextField, 'Podíl karty v panelu');
      expect(tester.widget<TextField>(share).controller!.text, '30');
      expect(find.text('Kolik výšky panelu karta zabere; zbytek si dělí '
          'nástěnka a zápasy.'), findsOneWidget);
      // Right under its switch, still in the duty's section.
      expect(
        tester.getTopLeft(share).dy,
        greaterThan(
            tester.getTopLeft(find.widgetWithText(SwitchListTile, 'V panelu'))
                .dy),
      );
      expect(
        tester.getTopLeft(share).dy,
        lessThan(tester.getTopLeft(find.text('Postranní panel')).dy),
      );

      await enter(tester, 'Podíl karty v panelu', '95');
      expect(find.text('Zadej číslo od 10 do 90.'), findsOneWidget);
      expect(requests.where((r) => r.method == 'PATCH'), isEmpty);
      await enter(tester, 'Podíl karty v panelu', '50');
      expect(lastPatch(), {'kiosk_duty_share': 50});

      await tester.tap(find.widgetWithText(SwitchListTile, 'V panelu'));
      await tester.pumpAndSettle();
      expect(lastPatch(), {'kiosk_duty_drawer': false});
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

    // The defaults are in the fields: 60 s, 2 columns, 2 weeks back.
    String shown(String label) =>
        tester.widget<TextField>(find.widgetWithText(TextField, label))
            .controller!.text;
    expect(shown('Doba nečinnosti'), '60');
    expect(shown('Šířka panelu'), '2');
    expect(shown('Odehrané zápasy: týdnů zpět'), '2');

    await enter(tester, 'Doba nečinnosti', '300');
    expect(lastPatch(), {'kiosk_idle_seconds': 300});
    await enter(tester, 'Střídání oznamů', '20');
    expect(lastPatch(), {'kiosk_notices_rotation_seconds': 20});
    await enter(tester, 'Šířka panelu', '3');
    expect(lastPatch(), {'kiosk_drawer_columns': 3});
    await enter(tester, 'Podíl nástěnky na výšce panelu', '60');
    expect(lastPatch(), {'kiosk_notices_share': 60});
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
      top(find.text('Nástěnka')),
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
    final field = find.widgetWithText(TextField, 'Šířka panelu');
    await tester.ensureVisible(field);
    await tester.enterText(field, '3');
    // Focus moves on to another field: the first one commits.
    await tester.tap(find.widgetWithText(TextField, 'Doba nečinnosti'));
    await tester.pumpAndSettle();
    expect(jsonDecode(requests.lastWhere((r) => r.method == 'PATCH').body),
        {'kiosk_drawer_columns': 3});
  });

  testWidgets('the options come in sections: screen, notices, canteen duty, '
      'panel, live match, then the address and the accounts', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    final order = [
      top('Obrazovka kiosku'),
      top('Stavový řádek'),
      top('Nástěnka'),
      top('Služby na kantýně'),
      top('Postranní panel'),
      top('Hraný zápas'),
      top('Adresa pro tablet'),
      top('Kioskové účty'),
    ];
    for (var i = 1; i < order.length; i++) {
      expect(order[i - 1], lessThan(order[i]), reason: 'section $i');
    }
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

  testWidgets('the panel switch comes first, and what needs it hides with it',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(app(panelEnabled: false));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(SwitchListTile, 'Panel zapnutý'), findsOneWidget);
    for (final dependent in [
      'Výchozně rozbalený',
      'Zápasy v panelu',
      'Hraný zápas přes celý panel',
      // The duty's card has no drawer to go to; header and board stay.
      'V panelu',
    ]) {
      expect(find.widgetWithText(SwitchListTile, dependent), findsNothing);
    }
    expect(find.text('Šířka panelu'), findsNothing);
    expect(find.text('Podíl karty v panelu'), findsNothing);
    expect(find.text('Hraný zápas'), findsNothing);
    expect(find.widgetWithText(SwitchListTile, 'V záhlaví'), findsOneWidget);
    expect(find.widgetWithText(SwitchListTile, 'V kalendáři'), findsOneWidget);
    // The notices can still go to the status bar without the panel.
    expect(find.text('Kde se oznamy zobrazí'), findsOneWidget);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Panel zapnutý'));
    await tester.pumpAndSettle();
    expect(jsonDecode(requests.lastWhere((r) => r.method == 'PATCH').body),
        {'kiosk_panel_enabled': true});
  });

  testWidgets('a rotation shows only with what it rotates', (tester) async {
    tall(tester);
    await tester.pumpWidget(app(
      settings: const ScheduleSettings(
        laneCount: 4,
        trainingWeekdays: {1},
        bookingHorizonDays: 14,
        maxActiveReservations: 3,
        kioskNoticesMode: KioskNoticesMode.off,
        kioskLiveMode: false,
        tenantId: 't',
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Střídání oznamů'), findsNothing);
    expect(find.text('Střídání hraných zápasů'), findsNothing);
    expect(find.text('Kontrola výsledků'), findsNothing);
    // Without the notices the notices' share has nothing to share either.
    expect(find.text('Podíl nástěnky na výšce panelu'), findsNothing);
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
}
