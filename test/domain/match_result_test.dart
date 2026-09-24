import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';

void main() {
  group('MatchResult.fromJson', () {
    test('reads status, scores (numeric → num), and fetched_at', () {
      final r = MatchResult.fromJson(const {
        'match_id': 'm1',
        'status': 'in_progress',
        'match_type': 'TEAMS_OF_6',
        'discipline': 'T120',
        'home_points': 2.5,
        'away_points': 5.5,
        'home_total': 3460,
        'away_total': 3349,
        'home_fulls': 1780,
        'away_fulls': 1700,
        'home_spares': 120,
        'away_spares': 110,
        'home_errors': 40,
        'away_errors': 35,
        'home_set_points': 2,
        'away_set_points': 4,
        'fetched_at': '2026-09-23T10:00:00+00:00',
      });
      expect(r.matchId, 'm1');
      expect(r.status, MatchStatus.inProgress);
      expect(r.matchType, 'TEAMS_OF_6');
      expect(r.discipline, 'T120');
      expect(r.homePoints, 2.5);
      expect(r.awayPoints, 5.5);
      expect(r.homeTotal, 3460);
      expect(r.awayTotal, 3349);
      expect(r.homeFulls, 1780);
      expect(r.awaySpares, 110);
      expect(r.homeErrors, 40);
      expect(r.awayErrors, 35);
      expect(r.homeSetPoints, 2);
      expect(r.awaySetPoints, 4);
      expect(r.fetchedAt, DateTime.utc(2026, 9, 23, 10));
    });

    test('parses every DB status string', () {
      MatchStatus statusOf(String s) => MatchResult.fromJson({
            'match_id': 'm',
            'status': s,
            'fetched_at': '2026-09-23T10:00:00+00:00',
          }).status;
      expect(statusOf('scheduled'), MatchStatus.scheduled);
      expect(statusOf('preparation'), MatchStatus.preparation);
      expect(statusOf('in_progress'), MatchStatus.inProgress);
      expect(statusOf('finished'), MatchStatus.finished);
      expect(statusOf('forfeit'), MatchStatus.forfeit);
    });

    test('scores are all null before the match has any', () {
      final r = MatchResult.fromJson(const {
        'match_id': 'm2',
        'status': 'scheduled',
        'fetched_at': '2026-09-23T10:00:00+00:00',
      });
      expect(r.homePoints, isNull);
      expect(r.awayPoints, isNull);
      expect(r.homeTotal, isNull);
      expect(r.homeSetPoints, isNull);
    });
  });

  group('MatchPlayerResult.fromJson', () {
    test('reads player fields and lanes', () {
      final p = MatchPlayerResult.fromJson(const {
        'id': 'pr1',
        'match_id': 'm1',
        'side': 'home',
        'position': 1,
        'player_name': 'Jan Novák',
        'player_slug': 'jan-novak',
        'fulls': 350,
        'spares': 20,
        'errors': 5,
        'total': 580,
        'set_points': 2,
        'team_points': 1,
        'lanes': [
          {
            'lane': 1,
            'fulls': 175,
            'spares': 10,
            'errors': 2,
            'total': 290,
            'setPoints': 1,
          },
          {
            'lane': 2,
            'fulls': 175,
            'spares': 10,
            'errors': 3,
            'total': 290,
            'setPoints': 1,
          },
        ],
      });
      expect(p.id, 'pr1');
      expect(p.matchId, 'm1');
      expect(p.side, 'home');
      expect(p.position, 1);
      expect(p.playerName, 'Jan Novák');
      expect(p.playerSlug, 'jan-novak');
      expect(p.total, 580);
      expect(p.setPoints, 2);
      expect(p.teamPoints, 1);
      expect(p.lanes, hasLength(2));
      expect(p.lanes.first.lane, 1);
      expect(p.lanes.first.fulls, 175);
      expect(p.lanes.first.setPoints, 1);
      expect(p.lanes.last.errors, 3);
    });

    test('lanes default to empty and playerSlug may be absent', () {
      final p = MatchPlayerResult.fromJson(const {
        'id': 'pr2',
        'match_id': 'm1',
        'side': 'away',
        'position': 4,
        'player_name': 'Náhradník',
      });
      expect(p.playerSlug, isNull);
      expect(p.lanes, isEmpty);
      expect(p.total, isNull);
    });
  });

  group('Venue.fromJson', () {
    test('reads sections (title + label/value items) and clubs', () {
      final v = Venue.fromJson(const {
        'id': 'v1',
        'slug': 'tj-sokol-brno-iv',
        'name': 'TJ Sokol Brno IV',
        'address': 'Kotlářská 21, Brno',
        'phone': '+420123456789',
        'email': 'info@sokolbrnoiv.cz',
        'lat': 49.2075,
        'lng': 16.6088,
        'sections': [
          {
            'title': 'Technické údaje',
            'items': [
              {'label': 'Drah', 'value': '4'},
              {'label': 'Stavěč', 'value': 'automatický'},
            ],
          },
        ],
        'clubs': ['TJ Sokol Brno IV', 'KS Devítka Brno'],
        'fetched_at': '2026-09-23T01:00:00+00:00',
      });
      expect(v.name, 'TJ Sokol Brno IV');
      expect(v.lat, 49.2075);
      expect(v.lng, 16.6088);
      expect(v.sections, hasLength(1));
      expect(v.sections.first.title, 'Technické údaje');
      expect(v.sections.first.items, hasLength(2));
      expect(v.sections.first.items.first.label, 'Drah');
      expect(v.sections.first.items.first.value, '4');
      expect(v.clubs, ['TJ Sokol Brno IV', 'KS Devítka Brno']);
    });

    test('lat/lng arrive as JSON int too (numeric → num?.toDouble())', () {
      final v = Venue.fromJson(const {
        'id': 'v2',
        'slug': 's',
        'name': 'N',
        'lat': 49,
        'lng': 16,
        'fetched_at': '2026-09-23T01:00:00+00:00',
      });
      expect(v.lat, 49.0);
      expect(v.lng, 16.0);
    });

    test('mapsUrl: coordinates win over address', () {
      final v = Venue.fromJson(const {
        'id': 'v3',
        'slug': 's',
        'name': 'N',
        'address': 'Nějaká 1, Brno',
        'lat': 49.2075,
        'lng': 16.6088,
        'fetched_at': '2026-09-23T01:00:00+00:00',
      });
      expect(v.mapsUrl,
          'https://www.google.com/maps/search/?api=1&query=49.2075,16.6088');
    });

    test('mapsUrl: address only, URL-encoded', () {
      final v = Venue.fromJson(const {
        'id': 'v4',
        'slug': 's',
        'name': 'N',
        'address': 'Kotlářská 21, Brno',
        'fetched_at': '2026-09-23T01:00:00+00:00',
      });
      expect(v.mapsUrl,
          'https://www.google.com/maps/search/?api=1&query=Kotl%C3%A1%C5%99sk%C3%A1%2021%2C%20Brno');
    });

    test('mapsUrl: neither coordinates nor address → null', () {
      final v = Venue.fromJson(const {
        'id': 'v5',
        'slug': 's',
        'name': 'N',
        'fetched_at': '2026-09-23T01:00:00+00:00',
      });
      expect(v.mapsUrl, isNull);
    });
  });

  group('PrioritySlot federation fields', () {
    test('fromJson reads video_url/competition/round/site_*/venue*', () {
      final m = PrioritySlot.fromJson(const {
        'id': 'm1',
        'date': '2026-09-27',
        'starts_at': '10:00:00',
        'ends_at': '13:00:00',
        'home_team': 'TJ Sokol Brno IV A',
        'away_team': 'KS Devítka Brno A',
        'description': '',
        'import_key': 'cka:12345',
        'video_url': 'https://youtu.be/abc',
        'competition': 'Jihomoravská divize',
        'round': 5,
        'site_slug': 'tj-sokol-brno-iv-a-vs-ks-devitka-brno-a',
        'site_match_id': 12345,
        'venue': 'TJ Sokol Brno IV',
        'venue_slug': 'tj-sokol-brno-iv',
      }, const {});
      expect(m.videoUrl, 'https://youtu.be/abc');
      expect(m.competition, 'Jihomoravská divize');
      expect(m.round, 5);
      expect(m.siteSlug, 'tj-sokol-brno-iv-a-vs-ks-devitka-brno-a');
      expect(m.siteMatchId, 12345);
      expect(m.venue, 'TJ Sokol Brno IV');
      expect(m.venueSlug, 'tj-sokol-brno-iv');
      expect(m.siteUrl,
          'https://vysledky.kuzelky.cz/detail-zapasu/tj-sokol-brno-iv-a-vs-ks-devitka-brno-a');
    });

    test('new fields absent → all null, siteUrl null', () {
      final m = PrioritySlot.fromJson(const {
        'id': 'm2',
        'date': '2026-09-27',
        'starts_at': '10:00:00',
        'ends_at': '13:00:00',
        'home_team': 'Husky',
        'away_team': 'přátelák',
        'description': '',
      }, const {});
      expect(m.videoUrl, isNull);
      expect(m.competition, isNull);
      expect(m.round, isNull);
      expect(m.siteSlug, isNull);
      expect(m.siteMatchId, isNull);
      expect(m.venue, isNull);
      expect(m.venueSlug, isNull);
      expect(m.siteUrl, isNull);
    });

    test('fromFederation: true only for a cka: import_key', () {
      PrioritySlot slot({String? importKey}) => PrioritySlot.fromJson({
            'id': 'x',
            'date': '2026-09-27',
            'starts_at': '10:00:00',
            'ends_at': '13:00:00',
            'home_team': 'A',
            'away_team': 'B',
            'description': '',
            'import_key': importKey,
          }, const {});
      expect(slot(importKey: 'cka:12345').fromFederation, isTrue);
      expect(slot(importKey: 'rozpis:JM divize:1:A – B').fromFederation, isFalse);
      expect(slot().fromFederation, isFalse);
    });
  });
}
