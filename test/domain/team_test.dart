import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';

void main() {
  test('Team.fromJson reads every column', () {
    final t = Team.fromJson({
      'id': 't1', 'name': 'TJ Sokol Brno IV A', 'club_id': 'c1',
      'site_slug': 'tj-sokol-brno-iv-muzi', 'site_name': 'TJ Sokol Brno IV',
      'competition_slug': 'jihomoravska-divize-2026-2027',
      'competition_name': 'Jihomoravská divize', 'active': false,
    });
    expect(t.name, 'TJ Sokol Brno IV A');
    expect(t.clubId, 'c1');
    expect(t.competitionName, 'Jihomoravská divize');
    expect(t.active, isFalse);
  });

  test('FederationSync.fromJson and none', () {
    expect(FederationSync.none.configured, isFalse);
    final s = FederationSync.fromJson({
      'venue_slug': 'tj-sokol-brno-iv', 'enabled': true,
      'last_run_at': '2026-09-23T01:00:00+00:00', 'last_success_at': null,
      'last_error': 'competition: HTTP 500',
    });
    expect(s.configured, isTrue);
    expect(s.enabled, isTrue);
    expect(s.lastRunAt, DateTime.utc(2026, 9, 23, 1));
    expect(s.lastSuccessAt, isNull);
    expect(s.lastError, 'competition: HTTP 500');
  });
}
