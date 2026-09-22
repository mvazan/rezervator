import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/public_week.dart';

void main() {
  // What public_week returns (0043), trimmed to one row per list.
  final json = <String, dynamic>{
    'tenant_name': 'Kuželna Test',
    'settings': {
      'lane_count': 2,
      'training_weekdays': [1, 2, 3, 4, 5, 6, 7],
      'booking_horizon_days': 14,
      'max_active_reservations': 3,
      'kiosk_dark': true,
      'kiosk_fit_day': true,
    },
    'blocks': [
      {'id': 'b1', 'starts_at': '10:00:00', 'ends_at': '11:00:00', 'position': 0, 'active': true},
    ],
    'slot_types': [
      {'id': 't-match', 'name': 'Zápas', 'color': -1, 'lanes': null, 'is_match': true, 'builtin': true},
    ],
    'overrides': [
      {'date': '2026-09-12', 'closed': true, 'reason': 'Údržba', 'block_ids': null},
    ],
    'priority_slots': [
      {
        'id': 'm1', 'date': '2026-09-11', 'starts_at': '10:00:00', 'ends_at': '11:00:00',
        'type_id': 't-match', 'home_team': 'Sokol', 'away_team': 'Slavia',
        'prep_minutes': 0, 'description': '', 'parent_id': null, 'is_away': false,
        'import_key': null, 'hand_edited': false,
      },
    ],
    'rentals': [
      {
        'id': 'r1', 'renter_name': '', 'lanes': [2], 'date': '2026-09-10', 'weekday': null,
        'starts_at': '10:00:00', 'ends_at': '11:00:00', 'valid_from': null, 'valid_until': null,
        'note': '', 'color': -2, 'parent_id': null, 'skipped': false, 'group_id': null,
      },
    ],
    'occupied': [
      {'block_id': 'b1', 'date': '2026-09-09', 'lane': 1, 'club_color': 3},
      {'block_id': 'b1', 'date': '2026-09-09', 'lane': 2, 'club_color': -1},
    ],
  };

  test('PublicWeek.fromJson reads every list with the app\'s own factories', () {
    final w = PublicWeek.fromJson(json);
    expect(w.tenantName, 'Kuželna Test');
    expect(w.settings.laneCount, 2);
    expect(w.blocks.single.id, 'b1');
    expect(w.overrides.single.closed, isTrue);
    expect(w.prioritySlots.single.title, 'Sokol – Slavia');
    expect(w.prioritySlots.single.type.isMatch, isTrue);
    expect(w.rentals.single.lanes, [2]);
  });

  test('a rental says Obsazeno — the server sent no name', () {
    expect(PublicWeek.fromJson(json).rentals.single.renterName, publicOccupiedLabel);
    expect(publicOccupiedLabel, 'Obsazeno');
  });

  test('each occupied cell becomes one live reservation named Obsazeno in its club colour', () {
    final w = PublicWeek.fromJson(json);
    expect(w.reservations, hasLength(2));
    final first = w.reservations.first;
    expect(first.blockId, 'b1');
    expect(first.date, Day(2026, 9, 9));
    expect(first.lane, 1);
    expect(first.isLive, isTrue);
    expect(first.createdVia, 'public');
    // Two cells, two distinct ids — the board keys tiles by them.
    expect(w.reservations.map((r) => r.id).toSet(), hasLength(2));
    for (final r in w.reservations) {
      expect(r.playerId, r.id);
      expect(w.nameById[r.playerId], 'Obsazeno');
    }
    expect(w.clubColorById[first.playerId], 3);
    expect(w.clubColorById[w.reservations.last.playerId], -1);
  });

  test('missing lists and settings fall back to empty / defaults', () {
    final w = PublicWeek.fromJson({'tenant_name': 'X'});
    expect(w.blocks, isEmpty);
    expect(w.reservations, isEmpty);
    expect(w.settings.laneCount, ScheduleSettings.defaults.laneCount);
  });

  test('PublicOverview.fromJson', () {
    final o = PublicOverview.fromJson(
        {'public_slug': null, 'public_enabled': false, 'tenant_name': 'Kuželna A'});
    expect(o.slug, isNull);
    expect(o.enabled, isFalse);
    expect(o.tenantName, 'Kuželna A');
  });
}
