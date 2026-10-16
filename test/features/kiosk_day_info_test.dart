import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/data/open_meteo.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/kiosk_header.dart';
import 'package:rezervator/domain/kiosk_layout.dart' show PanelSide;
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/namedays.dart';
import 'package:rezervator/domain/weather.dart';
import 'package:rezervator/features/kiosk/kiosk_day_info.dart';
import 'package:rezervator/features/kiosk/kiosk_header_module.dart';

void main() {
  // Saturday 3 January 2026, 10:00 — Radmila.
  final now = DateTime(2026, 1, 3, 10);

  ScheduleSettings settings({
    PanelSide weather = PanelSide.off,
    bool place = true,
  }) => ScheduleSettings(
    laneCount: 4,
    trainingWeekdays: const {1, 2, 3, 4, 5, 6, 7},
    bookingHorizonDays: 14,
    maxActiveReservations: 3,
    kioskHeader: KioskHeader.defaults.withSide(
      KioskHeaderModule.weather,
      weather,
    ),
    kioskWeatherPlace: place ? 'Brno, Jihomoravský' : null,
    kioskWeatherLat: place ? 49.19522 : null,
    kioskWeatherLon: place ? 16.60796 : null,
  );

  KioskWeather weather({
    double t = -3.4,
    int? chance = 10,
    bool isDay = true,
  }) => KioskWeather(
    temperature: t,
    kind: WeatherKind.snow,
    isDay: isDay,
    max: 1.2,
    min: -6.8,
    precipitationChance: chance,
    fetchedAt: now.subtract(const Duration(minutes: 10)),
  );

  /// Every value the admin may pick (0082), each worth showing: the gusts
  /// well above the wind, rain likely and some of it in the sum.
  KioskWeather full({
    double? feels = -8.6,
    double? wind = 12.3,
    double? gusts = 27.8,
    int? chance = 60,
    double? sum = 2.6,
  }) => KioskWeather(
    temperature: -3.4,
    kind: WeatherKind.snow,
    isDay: true,
    max: 1.2,
    min: -6.8,
    precipitationChance: chance,
    feelsLike: feels,
    wind: wind,
    gusts: gusts,
    precipitationSum: sum,
    fetchedAt: now.subtract(const Duration(minutes: 10)),
  );

  final all = KioskWeatherItem.values.toSet();

  Widget app(Widget module, {Size? size, double textScale = 1}) =>
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: Scaffold(
              body: Align(alignment: Alignment.topLeft, child: module),
            ),
          ),
        ),
      );

  final title = find.text('Brno:');

  testWidgets('the weather: the admin\'s title over the icon, now, today\'s '
      'high and low', (tester) async {
    await tester.pumpWidget(
      app(KioskWeatherModule(weather: weather(), title: 'Brno:')),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.cloudy_snowing), findsOneWidget);
    expect(find.text('−3°'), findsOneWidget);
    expect(find.text('1° / −7°'), findsOneWidget);
    expect(find.byIcon(Icons.umbrella), findsNothing);
    expect(title, findsOneWidget);
    // One tap target, read as the title and then the weather.
    expect(
      find.bySemanticsLabel(
        'Brno:\n'
        'Počasí: Sněžení, −3°, dnes nejvýš 1°, nejníž −7°. $weatherSource',
      ),
      findsOneWidget,
    );
    // The title over the value, both at the module's left.
    expect(
      tester.getRect(title).bottom,
      lessThanOrEqualTo(tester.getRect(find.text('−3°')).top),
    );
    expect(
      tester.getRect(title).left,
      tester.getRect(find.byIcon(Icons.cloudy_snowing)).left,
    );
  });

  testWidgets('from a 30 % chance of rain or snow the umbrella shows', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(KioskWeatherModule(weather: weather(chance: 30), title: 'Počasí')),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.umbrella), findsOneWidget);
    expect(find.text('30 %'), findsOneWidget);
  });

  group('the values the admin picks (0082)', () {
    const texts = {
      KioskWeatherItem.range: '1° / −7°',
      KioskWeatherItem.feels: 'pocitově −9°',
      KioskWeatherItem.wind: '12 km/h, nárazy 28',
      KioskWeatherItem.rain: '60 %, 3 mm',
    };

    for (final item in KioskWeatherItem.values) {
      testWidgets('${item.name} alone: ${texts[item]} beside the '
          'temperature, nothing else', (tester) async {
        await tester.pumpWidget(
          app(
            KioskWeatherModule(
              weather: full(),
              title: 'Brno:',
              items: {item},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.cloudy_snowing), findsOneWidget);
        expect(find.text('−3°'), findsOneWidget);
        for (final other in KioskWeatherItem.values) {
          expect(
            find.text(texts[other]!),
            other == item ? findsOneWidget : findsNothing,
            reason: '$other',
          );
        }
        expect(
          find.byIcon(Icons.air),
          item == KioskWeatherItem.wind ? findsOneWidget : findsNothing,
        );
        expect(
          find.byIcon(Icons.umbrella),
          item == KioskWeatherItem.rain ? findsOneWidget : findsNothing,
        );
      });
    }

    testWidgets('all four after the icon and the temperature, in the '
        'enum\'s order, and read out in words', (tester) async {
      await tester.pumpWidget(
        app(KioskWeatherModule(weather: full(), title: 'Brno:', items: all)),
      );
      await tester.pumpAndSettle();
      final xs = [
        find.byIcon(Icons.cloudy_snowing),
        find.text('−3°'),
        find.text('1° / −7°'),
        find.text('pocitově −9°'),
        find.byIcon(Icons.air),
        find.text('12 km/h, nárazy 28'),
        find.byIcon(Icons.umbrella),
        find.text('60 %, 3 mm'),
      ].map((f) => tester.getRect(f).left).toList();
      for (var i = 1; i < xs.length; i++) {
        expect(xs[i], greaterThan(xs[i - 1]), reason: 'item $i');
      }
      expect(
        find.bySemanticsLabel(
          'Brno:\n'
          'Počasí: Sněžení, −3°, dnes nejvýš 1°, nejníž −7°, pocitově −9°, '
          'vítr 12 km/h, nárazy 28, srážky 60 %, 3 mm. $weatherSource',
        ),
        findsOneWidget,
      );
    });

    testWidgets('none picked: the temperature alone', (tester) async {
      await tester.pumpWidget(
        app(KioskWeatherModule(weather: full(), title: 'Brno:', items: {})),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.cloudy_snowing), findsOneWidget);
      expect(find.text('−3°'), findsOneWidget);
      for (final text in texts.values) {
        expect(find.text(text), findsNothing, reason: text);
      }
      expect(find.byIcon(Icons.air), findsNothing);
      expect(find.byIcon(Icons.umbrella), findsNothing);
      expect(
        find.bySemanticsLabel(
          'Brno:\nPočasí: Sněžení, −3°. $weatherSource',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a value the forecast lacks shows nothing, picked or not', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          KioskWeatherModule(
            weather: full(feels: null, wind: null, chance: null, sum: null),
            title: 'Brno:',
            items: all,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1° / −7°'), findsOneWidget);
      expect(find.textContaining('pocitově'), findsNothing);
      expect(find.byIcon(Icons.air), findsNothing);
      expect(find.byIcon(Icons.umbrella), findsNothing);
    });

    // The umbrella when rain or snow is likely: a chance of at least 30 %
    // or a sum of at least 0.1 mm — each shown when it alone would do.
    for (final (chance, sum, shown) in [
      (29, 0.05, null),
      (29, null, null),
      (null, null, null),
      (30, 0.0, '30 %'),
      (10, 0.1, '< 1 mm'),
      (10, 0.94, '< 1 mm'),
      (10, 1.0, '1 mm'),
      (null, 4.4, '4 mm'),
      (60, 2.5, '60 %, 3 mm'),
    ]) {
      testWidgets('rain: a $chance % chance and $sum mm show '
          '${shown ?? 'no umbrella'}', (tester) async {
        await tester.pumpWidget(
          app(
            KioskWeatherModule(
              weather: full(chance: chance, sum: sum),
              title: 'Brno:',
              items: {KioskWeatherItem.rain},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byIcon(Icons.umbrella),
          shown == null ? findsNothing : findsOneWidget,
        );
        if (shown != null) expect(find.text(shown), findsOneWidget);
      });
    }

    testWidgets('a sum under 1 mm is read „méně než 1 mm“', (tester) async {
      await tester.pumpWidget(
        app(
          KioskWeatherModule(
            weather: full(chance: 10, sum: 0.3),
            title: 'Brno:',
            items: {KioskWeatherItem.rain},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(
          'Brno:\n'
          'Počasí: Sněžení, −3°, srážky méně než 1 mm. $weatherSource',
        ),
        findsOneWidget,
      );
    });

    // The gusts when they blow at least 10 km/h above the wind, both as
    // shown (rounded).
    for (final (wind, gusts, shown) in [
      (12.3, 21.4, '12 km/h'),
      (12.3, 21.6, '12 km/h, nárazy 22'),
      (12.3, null, '12 km/h'),
      (0.4, 9.6, '0 km/h, nárazy 10'),
    ]) {
      testWidgets('wind $wind with gusts $gusts: $shown', (tester) async {
        await tester.pumpWidget(
          app(
            KioskWeatherModule(
              weather: full(wind: wind, gusts: gusts),
              title: 'Brno:',
              items: {KioskWeatherItem.wind},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.air), findsOneWidget);
        expect(find.text(shown), findsOneWidget);
      });
    }

    testWidgets('the default: the high and low and the umbrella, as before', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(KioskWeatherModule(weather: full(), title: 'Brno:')),
      );
      await tester.pumpAndSettle();
      expect(find.text('1° / −7°'), findsOneWidget);
      expect(find.text('60 %, 3 mm'), findsOneWidget);
      expect(find.textContaining('pocitově'), findsNothing);
      expect(find.byIcon(Icons.air), findsNothing);
    });
  });

  testWidgets('no source in the header; a tap on the weather shows it in '
      'place of the title for a while', (tester) async {
    await tester.pumpWidget(
      app(KioskWeatherModule(weather: weather(), title: 'Brno:')),
    );
    await tester.pumpAndSettle();
    expect(find.text(weatherSource), findsNothing);
    expect(find.textContaining('Open-Meteo'), findsNothing);
    final at = tester.getRect(title).topLeft;

    await tester.tap(find.text('−3°'));
    await tester.pump();
    expect(find.text(weatherSource), findsOneWidget);
    expect(title, findsNothing);
    // Where the title was.
    expect(tester.getRect(find.text(weatherSource)).topLeft, at);

    await tester.pump(KioskWeatherModule.sourceFor);
    expect(find.text(weatherSource), findsNothing);
    expect(title, findsOneWidget);
  });

  testWidgets('a clear night shows the moon', (tester) async {
    await tester.pumpWidget(
      app(
        KioskWeatherModule(
          weather: KioskWeather(
            temperature: 4,
            kind: WeatherKind.clear,
            isDay: false,
            fetchedAt: now,
          ),
          title: 'Počasí',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.nightlight_round), findsOneWidget);
    expect(find.byIcon(Icons.wb_sunny), findsNothing);
  });

  testWidgets('the name day: its title over the names', (tester) async {
    await tester.pumpWidget(
      app(
        KioskNameDayModule(
          day: nameDayHeader(czechNameDay(Day(2026, 1, 3)))!,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final name = find.text('Radmila');
    expect(find.text('Svátek slaví:'), findsOneWidget);
    expect(name, findsOneWidget);
    expect(
      tester.getRect(find.text('Svátek slaví:')).bottom,
      lessThanOrEqualTo(tester.getRect(name).top),
    );
    expect(
      tester.getRect(find.text('Svátek slaví:')).left,
      tester.getRect(name).left,
    );
  });

  testWidgets('a narrow kiosk with large text: the weather with every value '
      'keeps to 0.3 of the screen and scales down, the names to a fifth and '
      'are cut', (tester) async {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            KioskWeatherModule(
              weather: full(chance: 100, sum: 24.6),
              title: 'Brno:',
              items: all,
            ),
            KioskNameDayModule(
              day: nameDayHeader(czechNameDay(Day(2026, 1, 6)))!,
            ),
          ],
        ),
        size: const Size(1024, 600),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final names = find.text('Kašpar, Melichar a Baltazar');
    expect(names, findsOneWidget);
    expect(
      tester.getSize(find.byType(KioskWeatherModule)).width,
      lessThanOrEqualTo(1024 * kioskHeaderWeatherShare),
    );
    // Scaled down: the row is wider than the room it is drawn in.
    expect(
      tester
          .getSize(
            find
                .descendant(
                  of: find.byType(KioskWeatherModule),
                  matching: find.byType(Row),
                )
                .first,
          )
          .width,
      greaterThan(1024 * kioskHeaderWeatherShare),
    );
    expect(
      tester.getSize(find.byType(KioskNameDayModule)).width,
      lessThanOrEqualTo(1024 * kioskHeaderModuleShare),
    );
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: names, matching: find.byType(RichText)),
    );
    expect(paragraph.didExceedMaxLines, isTrue);
  });

  group('kioskWeatherProvider', () {
    http.Response forecast() => http.Response.bytes(
      utf8.encode(
        jsonEncode({
          'current': {'temperature_2m': 7.6, 'weather_code': 3, 'is_day': 1},
          'daily': {
            'temperature_2m_max': [9],
            'temperature_2m_min': [2],
            'precipitation_probability_max': [0],
          },
        }),
      ),
      200,
    );

    Future<KioskWeather?> first(ScheduleSettings s, {List<Uri>? asked}) async {
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith((ref) => Stream.value(s)),
          openMeteoClientProvider.overrideWithValue(
            MockClient((req) async {
              asked?.add(req.url);
              return forecast();
            }),
          ),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(kioskWeatherProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(settingsProvider.future);
      return container.read(kioskWeatherProvider.future);
    }

    test('asks for the admin\'s place', () async {
      final asked = <Uri>[];
      final w = await first(settings(weather: PanelSide.left), asked: asked);
      expect(w?.temperature, 7.6);
      expect(w?.kind, WeatherKind.overcast);
      expect(asked.single.queryParameters['latitude'], '49.1952');
    });

    test('off, or without a place: nothing asked', () async {
      final asked = <Uri>[];
      expect(await first(settings(), asked: asked), isNull);
      expect(
        await first(
          settings(weather: PanelSide.left, place: false),
          asked: asked,
        ),
        isNull,
      );
      expect(asked, isEmpty);
    });

    test('on either side: asked', () async {
      for (final side in [PanelSide.left, PanelSide.right]) {
        final asked = <Uri>[];
        expect(await first(settings(weather: side), asked: asked), isNotNull);
        expect(asked, hasLength(1));
      }
    });
  });
}
