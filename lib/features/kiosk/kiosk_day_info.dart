/// The kiosk header's weather and name-day modules (0067, laid out by
/// 0081): today's weather at the admin's place under the admin's title,
/// and whose name day it is — each where the admin put it (Správa → Kiosk
/// → Záhlaví). The status bar leaves a module out while it has nothing to
/// say.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/open_meteo.dart';
import '../../data/providers.dart';
import '../../domain/kiosk_header.dart';
import '../../domain/weather.dart';
import 'kiosk_header_module.dart';

/// Today's weather at the admin's place, asked every half hour; null with
/// the weather off, without a place, or before the first answer.
final kioskWeatherProvider = StreamProvider.autoDispose<KioskWeather?>((ref) {
  final place = ref.watch(
    settingsProvider.select((s) {
      final v = s.value;
      return v == null || !v.kioskHeader.isOn(KioskHeaderModule.weather)
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

/// The weather module: the admin's title („Dnes v Brně“) over the icon,
/// the temperature and today's high and low, at most a fifth of the
/// screen (the row scales down). A tap shows the forecast's source in
/// place of the title for [sourceFor] — no watermark in the header
/// otherwise, the credit is a tap away.
class KioskWeatherModule extends StatefulWidget {
  const KioskWeatherModule({
    super.key,
    required this.weather,
    required this.title,
  });

  /// How long a tap on the weather shows its source in place of the title.
  static const sourceFor = Duration(seconds: 8);

  /// A fresh forecast ([freshWeather]); the bar leaves the module out
  /// without one.
  final KioskWeather weather;
  final String title;

  @override
  State<KioskWeatherModule> createState() => _KioskWeatherModuleState();
}

class _KioskWeatherModuleState extends State<KioskWeatherModule> {
  /// A visitor tapped the weather: its source shows for a while.
  Timer? _source;

  @override
  void dispose() {
    _source?.cancel();
    super.dispose();
  }

  void _showSource() {
    _source?.cancel();
    setState(() {
      _source = Timer(KioskWeatherModule.sourceFor, () {
        if (mounted) setState(() => _source = null);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return KioskHeaderModuleFrame(
      title: _source != null ? weatherSource : widget.title,
      maxWidth: MediaQuery.sizeOf(context).width * kioskHeaderModuleShare,
      onTap: _showSource,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: _Weather(
          weather: widget.weather,
          quiet: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// The name-day module: „Dnes má svátek“ over „Hedvika“ (`nameDayHeader`),
/// one line of at most a fifth of the screen — a long list of names is
/// cut.
class KioskNameDayModule extends StatelessWidget {
  const KioskNameDayModule({super.key, required this.day});

  final ({String title, String text}) day;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return KioskHeaderModuleFrame(
      title: day.title,
      maxWidth: MediaQuery.sizeOf(context).width * kioskHeaderModuleShare,
      child: Text(
        day.text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: kioskHeaderNameStyle(scheme),
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
      label: 'Počasí: $label. $weatherSource',
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
