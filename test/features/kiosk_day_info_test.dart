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

  testWidgets('a narrow kiosk with large text: each module keeps to a fifth '
      'of the screen — the weather scales down, the names are cut', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            KioskWeatherModule(
              weather: weather(t: -12.4, chance: 100),
              title: 'Brno:',
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
    for (final module in [
      find.byType(KioskWeatherModule),
      find.byType(KioskNameDayModule),
    ]) {
      expect(
        tester.getSize(module).width,
        lessThanOrEqualTo(1024 * kioskHeaderModuleShare),
      );
    }
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
