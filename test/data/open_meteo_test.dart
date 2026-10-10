import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/data/open_meteo.dart';
import 'package:rezervator/domain/weather.dart';

void main() {
  http.Response json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  final forecast = {
    'current': {'temperature_2m': 12.4, 'weather_code': 2, 'is_day': 1},
    'daily': {
      'temperature_2m_max': [15],
      'temperature_2m_min': [6],
      'precipitation_probability_max': [10],
    },
  };

  test('fetchWeather asks for the place and stamps the answer', () async {
    Uri? asked;
    final client = MockClient((req) async {
      asked = req.url;
      return json(forecast);
    });
    final at = DateTime(2026, 10, 10, 9);
    final w = await fetchWeather(client, 49.19, 16.63, clock: () => at);
    expect(asked?.queryParameters['latitude'], '49.1900');
    expect(w?.kind, WeatherKind.partlyCloudy);
    expect(w?.fetchedAt, at);
  });

  test('fetchWeather: an error answer is no weather', () async {
    final client = MockClient((_) async => json({'error': true}, 500));
    expect(await fetchWeather(client, 49.19, 16.63), isNull);
  });

  test('searchWeatherPlaces: Czech diacritics survive, a short query asks '
      'nothing, a failure throws', () async {
    var asked = 0;
    final ok = MockClient((_) async {
      asked++;
      return json({
        'results': [
          {
            'name': 'Žďár nad Sázavou',
            'latitude': 49.56,
            'longitude': 15.94,
            'country_code': 'CZ',
            'admin1': 'Kraj Vysočina',
          },
        ],
      });
    });
    expect(await searchWeatherPlaces(ok, ' '), isEmpty);
    expect(asked, 0);
    final places = await searchWeatherPlaces(ok, 'Žďár');
    expect(places.single.label, 'Žďár nad Sázavou, Kraj Vysočina');

    final down = MockClient((_) async => json({}, 503));
    expect(searchWeatherPlaces(down, 'Brno'), throwsStateError);
  });

  test('weatherStream: at once, then on the timer; a failure keeps the last '
      'answer; the timer dies with the subscription', () {
    fakeAsync((async) {
      var calls = 0;
      final answers = <KioskWeather?>[];
      KioskWeather w(double t) => KioskWeather(
        temperature: t,
        kind: WeatherKind.clear,
        isDay: true,
        fetchedAt: DateTime(2026, 10, 10),
      );
      Future<KioskWeather?> fetch() async {
        calls++;
        return switch (calls) {
          1 => w(10),
          2 => throw StateError('offline'),
          3 => null,
          _ => w(14),
        };
      }

      final sub = weatherStream(
        fetch,
        every: const Duration(minutes: 30),
      ).listen(answers.add);
      async.flushMicrotasks();
      expect([for (final a in answers) a?.temperature], [10]);

      async.elapse(const Duration(minutes: 30));
      async.elapse(const Duration(minutes: 30));
      async.elapse(const Duration(minutes: 30));
      expect([for (final a in answers) a?.temperature], [10, 10, 10, 14]);

      sub.cancel();
      async.elapse(const Duration(hours: 2));
      expect(calls, 4);
      expect(async.pendingTimers, isEmpty);
    });
  });
}
