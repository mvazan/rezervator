import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:rezervator/core/ui.dart';
import 'package:rezervator/domain/models.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// A url_launcher that records what it was asked to open and answers with
/// [accepts] per scheme.
class _FakeLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  @override
  LinkDelegate? get linkDelegate => null;

  _FakeLauncher({this.geoAccepted = true});

  final bool geoAccepted;
  final launched = <String>[];

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return url.startsWith('geo:') ? geoAccepted : true;
  }
}

/// Navigation to a venue: Android hands the place to the system's chooser of
/// maps apps (`geo:`), the other platforms — and an Android with no app for
/// it — open the Google Maps link.
void main() {
  final venue = Venue(
    id: 'v',
    slug: 's',
    name: 'Kuželna',
    address: 'Kotlářská 21, Brno',
    lat: 49.2075,
    lng: 16.6088,
    fetchedAt: DateTime.utc(2026, 9, 23),
  );
  const geo = 'geo:49.2075,16.6088?q=49.2075,16.6088';
  const web = 'https://www.google.com/maps/search/?api=1&query=49.2075,16.6088';

  late UrlLauncherPlatform original;
  setUp(() => original = UrlLauncherPlatform.instance);
  tearDown(() {
    UrlLauncherPlatform.instance = original;
    debugDefaultTargetPlatformOverride = null;
  });

  Future<List<String>> launch(
    Venue v,
    TargetPlatform p, {
    bool geoOk = true,
  }) async {
    debugDefaultTargetPlatformOverride = p;
    final fake = _FakeLauncher(geoAccepted: geoOk);
    UrlLauncherPlatform.instance = fake;
    await launchVenueMap(v);
    // launchWeb is fire-and-forget.
    await Future<void>.delayed(Duration.zero);
    return fake.launched;
  }

  test('Android: the geo: URI, so the system offers its maps apps', () async {
    expect(await launch(venue, TargetPlatform.android), [geo]);
  });

  test(
    'Android with no app for geo: falls back to the Google Maps link',
    () async {
      expect(await launch(venue, TargetPlatform.android, geoOk: false), [
        geo,
        web,
      ]);
    },
  );

  test('iOS: the Google Maps link', () async {
    expect(await launch(venue, TargetPlatform.iOS), [web]);
  });

  test('a venue with nothing to navigate to opens nothing', () async {
    final nowhere = Venue(
      id: 'v',
      slug: 's',
      name: 'N',
      fetchedAt: DateTime.utc(2026, 9, 23),
    );
    expect(await launch(nowhere, TargetPlatform.android), isEmpty);
  });
}
