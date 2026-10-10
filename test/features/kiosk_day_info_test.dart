import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/open_meteo.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/weather.dart';
import 'package:rezervator/features/kiosk/kiosk_day_info.dart';

void main() {
  // Saturday 3 January 2026, 10:00 — Radmila.
  final now = DateTime(2026, 1, 3, 10);

  ScheduleSettings settings({
    bool weather = false,
    bool nameday = false,
    bool place = true,
  }) => ScheduleSettings(
    laneCount: 4,
    trainingWeekdays: const {1, 2, 3, 4, 5, 6, 7},
    bookingHorizonDays: 14,
    maxActiveReservations: 3,
    kioskWeather: weather,
    kioskNameday: nameday,
    kioskWeatherPlace: place ? 'Brno, Jihomoravský' : null,
    kioskWeatherLat: place ? 49.19522 : null,
    kioskWeatherLon: place ? 16.60796 : null,
  );

  KioskWeather weather({
    double t = -3.4,
    int? chance = 10,
    DateTime? at,
    bool isDay = true,
  }) => KioskWeather(
    temperature: t,
    kind: WeatherKind.snow,
    isDay: isDay,
    max: 1.2,
    min: -6.8,
    precipitationChance: chance,
    fetchedAt: at ?? now.subtract(const Duration(minutes: 10)),
  );

  Widget app(ScheduleSettings s, {KioskWeather? w}) => ProviderScope(
    overrides: [
      settingsProvider.overrideWith((ref) => Stream.value(s)),
      nowProvider.overrideWith((ref) => Stream.value(now)),
      kioskWeatherProvider.overrideWith((ref) => Stream.value(w)),
    ],
    child: const MaterialApp(
      home: Scaffold(body: Center(child: KioskDayInfo())),
    ),
  );

  testWidgets('both off: nothing at all', (tester) async {
    await tester.pumpWidget(app(settings(), w: weather()));
    await tester.pumpAndSettle();
    expect(find.byType(Text), findsNothing);
    expect(tester.getSize(find.byType(KioskDayInfo)), Size.zero);
  });

  testWidgets('the weather: icon, now, today\'s high and low; the name day '
      'under it', (tester) async {
    await tester.pumpWidget(
      app(settings(weather: true, nameday: true), w: weather()),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.cloudy_snowing), findsOneWidget);
    expect(find.text('−3°'), findsOneWidget);
    expect(find.text('1° / −7°'), findsOneWidget);
    expect(find.byIcon(Icons.umbrella), findsNothing);
    expect(find.text('Svátek: Radmila'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Počasí: Sněžení, −3°, dnes nejvýš 1°, nejníž −7°',
      ),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.text('Svátek: Radmila')).dy,
      greaterThan(tester.getTopLeft(find.text('−3°')).dy),
    );
  });

  testWidgets('from a 30 % chance of rain or snow the umbrella shows', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(settings(weather: true), w: weather(chance: 30)),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.umbrella), findsOneWidget);
    expect(find.text('30 %'), findsOneWidget);
    expect(find.text('Svátek: Radmila'), findsNothing);
  });

  testWidgets('weather older than three hours is not shown; the name day '
      'still is', (tester) async {
    await tester.pumpWidget(
      app(
        settings(weather: true, nameday: true),
        w: weather(at: now.subtract(const Duration(hours: 3))),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('−3°'), findsNothing);
    expect(find.text('Svátek: Radmila'), findsOneWidget);
  });

  testWidgets('a clear night shows the moon', (tester) async {
    await tester.pumpWidget(
      app(
        settings(weather: true),
        w: KioskWeather(
          temperature: 4,
          kind: WeatherKind.clear,
          isDay: false,
          fetchedAt: now,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.nightlight_round), findsOneWidget);
    expect(find.byIcon(Icons.wb_sunny), findsNothing);
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
      final w = await first(settings(weather: true), asked: asked);
      expect(w?.temperature, 7.6);
      expect(w?.kind, WeatherKind.overcast);
      expect(asked.single.queryParameters['latitude'], '49.1952');
    });

    test('off, or without a place: nothing asked', () async {
      final asked = <Uri>[];
      expect(await first(settings(), asked: asked), isNull);
      expect(
        await first(settings(weather: true, place: false), asked: asked),
        isNull,
      );
      expect(asked, isEmpty);
    });
  });
}
