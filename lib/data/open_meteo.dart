/// Open-Meteo (0067): today's weather for the kiosk's status line, and the
/// places the admin searches for it. No key, no account; the kiosk and the
/// admin's browser ask it directly.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../domain/weather.dart';

/// The client both ask through — tests put a MockClient here.
final openMeteoClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

const _timeout = Duration(seconds: 15);

Map<String, dynamic>? _json(http.Response res) {
  if (res.statusCode != 200) return null;
  final body = jsonDecode(utf8.decode(res.bodyBytes));
  return body is Map<String, dynamic> ? body : null;
}

/// Today's weather at [lat]/[lon], stamped [clock]'s now; null when the
/// service answers with anything but a forecast.
Future<KioskWeather?> fetchWeather(
  http.Client client,
  double lat,
  double lon, {
  DateTime Function() clock = DateTime.now,
}) async {
  final json = _json(
    await client.get(openMeteoForecastUri(lat, lon)).timeout(_timeout),
  );
  return json == null ? null : KioskWeather.fromOpenMeteo(json, clock());
}

/// The places named like [query]; empty for a blank query. Throws when
/// the service cannot be reached — the admin's dialog says so.
Future<List<WeatherPlace>> searchWeatherPlaces(
  http.Client client,
  String query,
) async {
  if (query.trim().length < 2) return const [];
  final json = _json(
    await client.get(openMeteoGeocodingUri(query)).timeout(_timeout),
  );
  if (json == null) throw StateError('geocoding answered badly');
  return parseGeocoding(json);
}

/// How soon a failed ask is repeated, doubling up to [weatherRetryMax] —
/// a kiosk that started before its Wi-Fi, or lost it a while, gets its
/// weather back within minutes, not at the next half hour.
const weatherRetry = Duration(minutes: 1);
const weatherRetryMax = Duration(minutes: 10);

/// The weather now and then every [every]: [fetch] at once, then on a
/// timer (cancelled with the subscription — no timer outlives the kiosk).
/// A failed or empty answer keeps the last good one (the status line
/// drops it once stale, [freshWeather]) and is asked again after [retry],
/// doubling up to [retryMax]; a good one goes back to [every].
Stream<KioskWeather?> weatherStream(
  Future<KioskWeather?> Function() fetch, {
  Duration every = weatherEvery,
  Duration retry = weatherRetry,
  Duration retryMax = weatherRetryMax,
}) {
  late final StreamController<KioskWeather?> out;
  Timer? timer;
  KioskWeather? last;
  var backoff = retry;
  var cancelled = false;

  Future<void> tick() async {
    KioskWeather? fresh;
    try {
      fresh = await fetch();
    } catch (_) {
      // The network or the service is down: the last answer stands.
    }
    if (cancelled) return;
    last = fresh ?? last;
    out.add(last);
    final Duration next;
    if (fresh != null) {
      backoff = retry;
      next = every;
    } else {
      next = backoff;
      backoff = backoff * 2 < retryMax ? backoff * 2 : retryMax;
    }
    timer = Timer(next, tick);
  }

  out = StreamController<KioskWeather?>(
    onListen: tick,
    onCancel: () {
      cancelled = true;
      timer?.cancel();
    },
  );
  return out.stream;
}
