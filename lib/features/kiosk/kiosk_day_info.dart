/// Beside the kiosk's clock (0067): today's weather and whose name day it
/// is — each when the admin switched it on (Správa → Kiosk → Stavový
/// řádek). Nothing at all when neither is on, or there is nothing to say.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/clock.dart';
import '../../data/open_meteo.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/namedays.dart';
import '../../domain/weather.dart';

/// Today's weather at the admin's place, asked every half hour; null with
/// the weather off, without a place, or before the first answer.
final kioskWeatherProvider = StreamProvider.autoDispose<KioskWeather?>((ref) {
  final place = ref.watch(
    settingsProvider.select((s) {
      final v = s.value;
      return v == null || !v.kioskWeather
          ? null
          : (v.kioskWeatherLat, v.kioskWeatherLon);
    }),
  );
  final (lat, lon) = place ?? (null, null);
  if (lat == null || lon == null) return Stream.value(null);
  final client = ref.watch(openMeteoClientProvider);
  return weatherStream(() => fetchWeather(client, lat, lon));
});

/// The icon for [kind] — a moon for a clear night.
IconData weatherIcon(WeatherKind kind, {required bool isDay}) =>
    switch (kind) {
      WeatherKind.clear || WeatherKind.mainlyClear =>
        isDay ? Icons.wb_sunny : Icons.nightlight_round,
      WeatherKind.partlyCloudy => Icons.filter_drama,
      WeatherKind.overcast => Icons.cloud,
      WeatherKind.fog => Icons.foggy,
      WeatherKind.drizzle => Icons.grain,
      WeatherKind.rain || WeatherKind.showers => Icons.water_drop,
      WeatherKind.freezingRain => Icons.ac_unit,
      WeatherKind.snow || WeatherKind.snowShowers => Icons.cloudy_snowing,
      WeatherKind.thunderstorm => Icons.thunderstorm,
    };

class KioskDayInfo extends ConsumerWidget {
  const KioskDayInfo({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value;
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final weather = (settings?.kioskWeather ?? false)
        ? freshWeather(ref.watch(kioskWeatherProvider).value, now)
        : null;
    final nameDay = (settings?.kioskNameday ?? false)
        ? nameDayLine(czechNameDay(Day.fromDateTime(now)))
        : null;
    if (weather == null && nameDay == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final quiet = TextStyle(fontSize: 14, color: scheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.only(left: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (weather != null) _Weather(weather: weather, quiet: quiet),
          if (nameDay != null) Text(nameDay, style: quiet),
        ],
      ),
    );
  }
}

class _Weather extends StatelessWidget {
  const _Weather({required this.weather, required this.quiet});

  final KioskWeather weather;
  final TextStyle quiet;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final max = weather.max;
    final min = weather.min;
    final chance = weather.precipitationChance;
    final rainy = chance != null && chance >= weatherUmbrellaFrom;
    final label = [
      weatherLabel(weather.kind),
      degrees(weather.temperature),
      if (max != null && min != null)
        'dnes nejvýš ${degrees(max)}, nejníž ${degrees(min)}',
      if (rainy) 'srážky $chance %',
    ].join(', ');
    return Semantics(
      label: 'Počasí: $label',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            weatherIcon(weather.kind, isDay: weather.isDay),
            size: 24,
            color: scheme.primary,
          ),
          const SizedBox(width: 6),
          Text(
            degrees(weather.temperature),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          if (max != null && min != null) ...[
            const SizedBox(width: 10),
            Text('${degrees(max)} / ${degrees(min)}', style: quiet),
          ],
          if (rainy) ...[
            const SizedBox(width: 10),
            Icon(Icons.umbrella, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 2),
            Text('$chance %', style: quiet),
          ],
        ],
      ),
    );
  }
}
