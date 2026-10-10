/// The weather on the kiosk's status line (0067): today's forecast for the
/// place the admin picked, from Open-Meteo (free, no key, CC BY 4.0 — the
/// admin section names the source). Pure: the addresses, the parsing and
/// the Czech words; the fetching lives in `data/open_meteo.dart`.
library;

/// What the sky does, from the WMO weather code Open-Meteo reports.
enum WeatherKind {
  clear,
  mainlyClear,
  partlyCloudy,
  overcast,
  fog,
  drizzle,
  rain,
  freezingRain,
  snow,
  showers,
  snowShowers,
  thunderstorm,
}

/// [code] (WMO 4677, as Open-Meteo uses it) as a [WeatherKind]; an
/// unknown code reads as overcast — a cloud is the safe guess.
WeatherKind weatherKindFor(int code) => switch (code) {
  0 => WeatherKind.clear,
  1 => WeatherKind.mainlyClear,
  2 => WeatherKind.partlyCloudy,
  3 => WeatherKind.overcast,
  45 || 48 => WeatherKind.fog,
  51 || 53 || 55 => WeatherKind.drizzle,
  56 || 57 || 66 || 67 => WeatherKind.freezingRain,
  61 || 63 || 65 => WeatherKind.rain,
  71 || 73 || 75 || 77 => WeatherKind.snow,
  80 || 81 || 82 => WeatherKind.showers,
  85 || 86 => WeatherKind.snowShowers,
  95 || 96 || 99 => WeatherKind.thunderstorm,
  _ => WeatherKind.overcast,
};

/// The kind in Czech, for the screen reader and the admin's preview.
String weatherLabel(WeatherKind kind) => switch (kind) {
  WeatherKind.clear => 'Jasno',
  WeatherKind.mainlyClear => 'Skoro jasno',
  WeatherKind.partlyCloudy => 'Polojasno',
  WeatherKind.overcast => 'Zataženo',
  WeatherKind.fog => 'Mlha',
  WeatherKind.drizzle => 'Mrholení',
  WeatherKind.rain => 'Déšť',
  WeatherKind.freezingRain => 'Mrznoucí déšť',
  WeatherKind.snow => 'Sněžení',
  WeatherKind.showers => 'Přeháňky',
  WeatherKind.snowShowers => 'Sněhové přeháňky',
  WeatherKind.thunderstorm => 'Bouřka',
};

/// A temperature as the kiosk prints it: whole degrees, a real minus sign,
/// never „−0“.
String degrees(double celsius) {
  final whole = celsius.round();
  if (whole == 0) return '0°';
  return whole < 0 ? '−${-whole}°' : '$whole°';
}

/// Today's weather at one place.
class KioskWeather {
  const KioskWeather({
    required this.temperature,
    required this.kind,
    required this.isDay,
    required this.fetchedAt,
    this.max,
    this.min,
    this.precipitationChance,
  });

  /// Now, in °C.
  final double temperature;
  final WeatherKind kind;

  /// Daylight at the place now (a clear night shows a moon, not a sun).
  final bool isDay;

  /// Today's high and low, in °C.
  final double? max;
  final double? min;

  /// Today's highest chance of rain or snow, in percent.
  final int? precipitationChance;

  /// When the kiosk got it — an answer older than [weatherStaleAfter] is
  /// not shown.
  final DateTime fetchedAt;

  /// Open-Meteo's forecast answer ([openMeteoForecastUri]); null when the
  /// current values are missing.
  static KioskWeather? fromOpenMeteo(
    Map<String, dynamic> json,
    DateTime fetchedAt,
  ) {
    final current = json['current'];
    if (current is! Map) return null;
    final temperature = current['temperature_2m'];
    final code = current['weather_code'];
    if (temperature is! num || code is! num) return null;
    T? firstOf<T extends num>(String key) {
      final daily = json['daily'];
      if (daily is! Map) return null;
      final values = daily[key];
      if (values is! List || values.isEmpty) return null;
      final v = values.first;
      return v is num ? v as T? : null;
    }

    return KioskWeather(
      temperature: temperature.toDouble(),
      kind: weatherKindFor(code.toInt()),
      isDay: current['is_day'] != 0,
      max: firstOf<num>('temperature_2m_max')?.toDouble(),
      min: firstOf<num>('temperature_2m_min')?.toDouble(),
      precipitationChance: firstOf<num>(
        'precipitation_probability_max',
      )?.round(),
      fetchedAt: fetchedAt,
    );
  }
}

/// How often the kiosk asks for the weather, and how old an answer may get
/// (the network gone a while) before the status line drops it rather than
/// show a morning's rain at night.
const weatherEvery = Duration(minutes: 30);
const weatherStaleAfter = Duration(hours: 3);

/// From this chance of rain or snow on, the status line shows the umbrella.
const weatherUmbrellaFrom = 30;

/// [weather] if it is still fresh at [now], else null.
KioskWeather? freshWeather(KioskWeather? weather, DateTime now) =>
    weather != null && now.difference(weather.fetchedAt) < weatherStaleAfter
    ? weather
    : null;

/// Today's forecast at [lat]/[lon]: now (temperature, code, daylight) and
/// the day (high, low, highest chance of rain), in Prague's day.
Uri openMeteoForecastUri(double lat, double lon) =>
    Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': lat.toStringAsFixed(4),
      'longitude': lon.toStringAsFixed(4),
      'current': 'temperature_2m,weather_code,is_day',
      'daily':
          'temperature_2m_max,temperature_2m_min,precipitation_probability_max',
      'timezone': 'Europe/Prague',
      'forecast_days': '1',
      // ČHMÚ's ALADIN model: 1 km over Czechia, the Central Europe domain
      // around it; Open-Meteo serves it like any other model.
      'models': weatherModel,
    });

/// The forecast model Open-Meteo is asked for: ČHMÚ's ALADIN (Czech
/// Hydrometeorological Institute), 1 km over Czechia.
const weatherModel = 'chmi_aladin_seamless';

/// Where the weather comes from, as the kiosk credits it on a tap (both
/// the model's maker and the service are CC BY: credit where it is shown).
const weatherSource = 'Zdroj: ČHMÚ (model ALADIN) přes Open-Meteo.com';

/// A place the admin can pick for the weather.
class WeatherPlace {
  const WeatherPlace({
    required this.label,
    required this.lat,
    required this.lon,
  });

  /// What the admin sees and the settings keep („Brno, Jihomoravský kraj“).
  final String label;
  final double lat;
  final double lon;
}

/// Places named like [query], Czech names first-class.
Uri openMeteoGeocodingUri(String query) =>
    Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
      'name': query.trim(),
      'count': '8',
      'language': 'cs',
      'format': 'json',
    });

/// Open-Meteo's geocoding answer as places: „name, district, region“ (the
/// district — „okres Kladno“ — tells apart the many villages of one name
/// in one region; left out when it only repeats the name, „Město Brno“),
/// the country when it is not Czechia, in the order the service ranks
/// them. Two places that still read the same get their coordinates.
List<WeatherPlace> parseGeocoding(Map<String, dynamic> json) {
  final results = json['results'];
  if (results is! List) return const [];
  final places = [
    for (final r in results)
      if (r is Map &&
          r['name'] is String &&
          r['latitude'] is num &&
          r['longitude'] is num)
        WeatherPlace(
          label: _placeLabel(r),
          lat: (r['latitude'] as num).toDouble(),
          lon: (r['longitude'] as num).toDouble(),
        ),
  ];
  final seen = <String, int>{};
  for (final p in places) {
    seen[p.label] = (seen[p.label] ?? 0) + 1;
  }
  return [
    for (final p in places)
      (seen[p.label] ?? 0) > 1
          ? WeatherPlace(
              label:
                  '${p.label} (${p.lat.toStringAsFixed(2)}, '
                  '${p.lon.toStringAsFixed(2)})',
              lat: p.lat,
              lon: p.lon,
            )
          : p,
  ];
}

String _placeLabel(Map<dynamic, dynamic> r) {
  final name = r['name'] as String;
  final czech = r['country_code'] == 'CZ';
  return [
    name,
    if (r['admin2'] case final String district
        when district.isNotEmpty &&
            !district.contains(name) &&
            district != r['admin1'])
      czech ? 'okres $district' : district,
    if (r['admin1'] case final String region
        when region.isNotEmpty && region != name)
      region,
    if (!czech)
      if (r['country'] case final String country) country,
  ].join(', ');
}
