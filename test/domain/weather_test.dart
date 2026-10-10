import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/weather.dart';

void main() {
  group('weatherKindFor', () {
    for (final (code, kind) in [
      (0, WeatherKind.clear),
      (1, WeatherKind.mainlyClear),
      (2, WeatherKind.partlyCloudy),
      (3, WeatherKind.overcast),
      (45, WeatherKind.fog),
      (48, WeatherKind.fog),
      (53, WeatherKind.drizzle),
      (57, WeatherKind.freezingRain),
      (63, WeatherKind.rain),
      (67, WeatherKind.freezingRain),
      (75, WeatherKind.snow),
      (77, WeatherKind.snow),
      (81, WeatherKind.showers),
      (86, WeatherKind.snowShowers),
      (95, WeatherKind.thunderstorm),
      (99, WeatherKind.thunderstorm),
      (42, WeatherKind.overcast),
    ]) {
      test('WMO $code is $kind', () => expect(weatherKindFor(code), kind));
    }
  });

  test('every kind has a Czech word', () {
    for (final k in WeatherKind.values) {
      expect(weatherLabel(k), isNotEmpty);
    }
    expect(weatherLabel(WeatherKind.partlyCloudy), 'Polojasno');
  });

  test('degrees: whole, a real minus sign, never minus zero', () {
    expect(degrees(15.7), '16°');
    expect(degrees(-3.4), '−3°');
    expect(degrees(-0.4), '0°');
    expect(degrees(0.4), '0°');
  });

  group('KioskWeather.fromOpenMeteo', () {
    final at = DateTime(2026, 10, 10, 16, 30);
    test('reads now and today', () {
      final w = KioskWeather.fromOpenMeteo({
        'current': {'temperature_2m': 15.7, 'weather_code': 61, 'is_day': 1},
        'daily': {
          'temperature_2m_max': [18.2],
          'temperature_2m_min': [9.1],
          'precipitation_probability_max': [40],
        },
      }, at)!;
      expect(w.temperature, 15.7);
      expect(w.kind, WeatherKind.rain);
      expect(w.isDay, isTrue);
      expect(w.max, 18.2);
      expect(w.min, 9.1);
      expect(w.precipitationChance, 40);
      expect(w.fetchedAt, at);
    });

    test('night, and a day without its figures', () {
      final w = KioskWeather.fromOpenMeteo({
        'current': {'temperature_2m': -2, 'weather_code': 0, 'is_day': 0},
        'daily': {
          'temperature_2m_max': <Object?>[null],
          'precipitation_probability_max': <Object?>[],
        },
      }, at)!;
      expect(w.isDay, isFalse);
      expect(w.temperature, -2);
      expect(w.max, isNull);
      expect(w.min, isNull);
      expect(w.precipitationChance, isNull);
    });

    test('no current values, no weather', () {
      expect(KioskWeather.fromOpenMeteo({'daily': {}}, at), isNull);
      expect(
        KioskWeather.fromOpenMeteo({
          'current': {'temperature_2m': 'x', 'weather_code': 1},
        }, at),
        isNull,
      );
    });
  });

  test('an answer older than three hours is not shown', () {
    final w = KioskWeather(
      temperature: 10,
      kind: WeatherKind.clear,
      isDay: true,
      fetchedAt: DateTime(2026, 10, 10, 12),
    );
    expect(freshWeather(w, DateTime(2026, 10, 10, 14, 59)), same(w));
    expect(freshWeather(w, DateTime(2026, 10, 10, 15)), isNull);
    expect(freshWeather(null, DateTime(2026, 10, 10, 12)), isNull);
  });

  test('the forecast address: the place, today, Prague time', () {
    final uri = openMeteoForecastUri(49.18917, 16.63547);
    expect(uri.host, 'api.open-meteo.com');
    expect(uri.queryParameters['latitude'], '49.1892');
    expect(uri.queryParameters['longitude'], '16.6355');
    expect(uri.queryParameters['current'], contains('weather_code'));
    expect(uri.queryParameters['daily'], contains('temperature_2m_max'));
    expect(uri.queryParameters['timezone'], 'Europe/Prague');
    expect(uri.queryParameters['forecast_days'], '1');
  });

  test('geocoding: Czech names, the region, the country only abroad', () {
    final uri = openMeteoGeocodingUri('  Brno ');
    expect(uri.host, 'geocoding-api.open-meteo.com');
    expect(uri.queryParameters['name'], 'Brno');
    expect(uri.queryParameters['language'], 'cs');

    final places = parseGeocoding({
      'results': [
        {
          'name': 'Brno',
          'latitude': 49.19522,
          'longitude': 16.60796,
          'country_code': 'CZ',
          'country': 'Česko',
          'admin1': 'Jihomoravský',
        },
        {
          'name': 'Bruno',
          'latitude': 41.28,
          'longitude': -96.95,
          'country_code': 'US',
          'country': 'Spojené státy americké',
          'admin1': 'Nebraska',
        },
        {'name': 'Bez souřadnic'},
      ],
    });
    expect([for (final p in places) p.label], [
      'Brno, Jihomoravský',
      'Bruno, Nebraska, Spojené státy americké',
    ]);
    expect(places.first.lat, 49.19522);
    expect(parseGeocoding({}), isEmpty);
  });
}
