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

  test('FederationSync.fromJson reads the last discovery report (0046)', () {
    final s = FederationSync.fromJson({
      'venue_slug': 'tj-sokol-brno-iv',
      'last_report': {
        'discover': {
          'teams': 5, 'competitions': 2, 'created': 5,
          'clubs_created': ['KS Devítka Brno'],
          'clubs_linked': ['Sokol Brno IV', 'Veverky'],
          'at': '2026-09-25T08:00:00+00:00',
        },
        'competition:jihomoravska-divize-2026-2027': {'inserted': 1},
      },
    });
    final r = s.discover!;
    expect(r.teams, 5);
    expect(r.competitions, 2);
    expect(r.created, 5);
    expect(r.clubsCreated, ['KS Devítka Brno']);
    expect(r.clubsLinked, ['Sokol Brno IV', 'Veverky']);
    expect(r.at, DateTime.utc(2026, 9, 25, 8));
    expect(r.failed, isFalse);

    expect(FederationSync.fromJson({'venue_slug': 'x'}).discover, isNull);
    final failed = FederationSync.fromJson({
      'last_report': {
        'discover': {'error': 'boom', 'at': '2026-09-25T08:00:00+00:00'},
      },
    }).discover!;
    expect(failed.failed, isTrue);
    expect(failed.error, 'boom');
    expect(failed.teams, 0);
    expect(failed.clubsCreated, isEmpty);
    expect(failed.teamsCreated, isEmpty);
  });

  test('FederationDiscoverReport reads teams_created, none when absent (0046)',
      () {
    final r = FederationDiscoverReport.fromJson({
      'teams': 5, 'competitions': 2, 'created': 2,
      'teams_created': ['KS Devítka Brno B', 'TJ Sokol Brno IV C'],
      'clubs_created': const [], 'clubs_linked': ['Sokol Brno IV'],
      'at': '2026-09-25T08:00:00+00:00',
    });
    expect(r.created, 2);
    expect(r.teamsCreated, ['KS Devítka Brno B', 'TJ Sokol Brno IV C']);

    // A report written before 0046 named the teams: counted, not named.
    final older = FederationDiscoverReport.fromJson({
      'teams': 5, 'created': 5, 'at': '2026-09-24T08:00:00+00:00',
    });
    expect(older.created, 5);
    expect(older.teamsCreated, isEmpty);
    expect(const FederationDiscoverReport().teamsCreated, isEmpty);
  });

  test('FederationSyncProgress.fromJson, pending and idle (0046)', () {
    final p = FederationSyncProgress.fromJson(
        {'discover': 0, 'competitions': 2, 'matches': 12, 'venues': 1});
    expect(p.discover, 0);
    expect(p.competitions, 2);
    expect(p.matches, 12);
    expect(p.venues, 1);
    expect(p.pending, isTrue);
    expect(FederationSyncProgress.idle.pending, isFalse);
    expect(FederationSyncProgress.fromJson(const {}), FederationSyncProgress.idle);
    expect(const FederationSyncProgress(matches: 1),
        const FederationSyncProgress(matches: 1));
  });
}
