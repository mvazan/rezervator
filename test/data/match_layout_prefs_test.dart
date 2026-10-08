import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/local_prefs.dart';
import 'package:rezervator/domain/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('parseMatchLayout: known names; anything else is the fallback; Zápis '
      'only where allowed', () {
    expect(parseMatchLayout('compact'), MatchLayout.compact);
    expect(parseMatchLayout('table'), MatchLayout.table);
    expect(parseMatchLayout('zapis'), MatchLayout.zapis);
    expect(parseMatchLayout('full'), MatchLayout.full);
    expect(parseMatchLayout(null), MatchLayout.full);
    expect(parseMatchLayout('x'), MatchLayout.full);
    expect(parseMatchLayout('x', fallback: MatchLayout.table), MatchLayout.table);
    // The kiosk's column and the portrait preference never carry Zápis.
    expect(parseMatchLayout('zapis', allowZapis: false), MatchLayout.full);
    expect(
      parseMatchLayout('zapis', allowZapis: false, fallback: MatchLayout.compact),
      MatchLayout.compact,
    );
  });

  test('kiosk settings: an unknown live layout reads as the full one', () {
    ScheduleSettings settings(Object? layout) => ScheduleSettings.fromJson({
      'lane_count': 4,
      'training_weekdays': [1],
      'booking_horizon_days': 14,
      'max_active_reservations': 3,
      'kiosk_live_layout': layout,
    });
    expect(settings('table').kioskLiveLayout, MatchLayout.table);
    expect(settings(null).kioskLiveLayout, MatchLayout.full);
    expect(settings('zapis').kioskLiveLayout, MatchLayout.full);
  });

  test('parseMatchLayoutPrefs: both names, Zápis in either', () {
    expect(
      parseMatchLayoutPrefs('compact', 'zapis'),
      (portrait: MatchLayout.compact, landscape: MatchLayout.zapis),
    );
    expect(parseMatchLayoutPrefs(null, null), defaultMatchLayoutPrefs);
    expect(
      parseMatchLayoutPrefs('zapis', 'x'),
      (portrait: MatchLayout.zapis, landscape: MatchLayout.full),
    );
  });

  test('defaults to the cards, loads the saved choice, saves a new one',
      () async {
    SharedPreferences.setMockInitialValues({
      'match_layout_portrait': 'table',
      'match_layout_landscape': 'zapis',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(matchLayoutPrefsProvider), defaultMatchLayoutPrefs);
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(matchLayoutPrefsProvider),
      (portrait: MatchLayout.table, landscape: MatchLayout.zapis),
    );

    // One orientation at a time; the other stays.
    await container
        .read(matchLayoutPrefsProvider.notifier)
        .set(portrait: MatchLayout.compact);
    expect(
      container.read(matchLayoutPrefsProvider),
      (portrait: MatchLayout.compact, landscape: MatchLayout.zapis),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('match_layout_portrait'), 'compact');
    expect(prefs.getString('match_layout_landscape'), 'zapis');

    await container
        .read(matchLayoutPrefsProvider.notifier)
        .set(landscape: MatchLayout.full);
    expect(prefs.getString('match_layout_landscape'), 'full');
  });
}
