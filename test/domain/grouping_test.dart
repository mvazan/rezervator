import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/grouping.dart';
import 'package:rezervator/domain/models.dart';

void main() {
  group('playersByClub', () {
    Profile player(String id, String name, {String? clubId}) => Profile(
      id: id,
      displayName: name,
      email: '$id@example.com',
      role: Role.player,
      status: ProfileStatus.approved,
      clubId: clubId,
    );

    const clubs = [
      Club(id: 'c2', name: 'Veverky', colorIndex: 2),
      Club(id: 'c1', name: 'Sokol Dlouhá Lhota', colorIndex: 1),
      Club(id: 'c3', name: 'Prázdný oddíl'),
    ];

    test('clubs by name, members by name, unaffiliated last, empty clubs '
        'skipped', () {
      final sections = playersByClub([
        player('p1', 'Zdeněk', clubId: 'c2'),
        player('p2', 'Adam'),
        player('p3', 'Cyril', clubId: 'c1'),
        player('p4', 'Blanka', clubId: 'c1'),
        // A club deleted from the roster counts as "Bez oddílu".
        player('p5', 'Dana', clubId: 'ghost'),
      ], clubs);

      expect(
        [for (final (club, _) in sections) club],
        ['Sokol Dlouhá Lhota', 'Veverky', null],
      );
      expect(
        [
          for (final (_, members) in sections)
            [for (final p in members) p.displayName],
        ],
        [
          ['Blanka', 'Cyril'],
          ['Zdeněk'],
          ['Adam', 'Dana'],
        ],
      );
    });

    test('no players yields no sections', () {
      expect(playersByClub(const [], clubs), isEmpty);
    });
  });

  group('attendanceByClub', () {
    AttendanceRow row(String name, String club, int attended) => AttendanceRow(
      playerId: name.toLowerCase(),
      displayName: name,
      club: club,
      attended: attended,
    );

    test('club sections alphabetically (Czech order), Bez oddílu last, '
        'players alphabetically within a section', () {
      final sections = attendanceByClub([
        row('Cyril', 'Veverky', 4),
        row('Blanka', 'Šohaj', 5),
        row('Adam', 'Veverky', 3), // Veverky total 7 — totals do not order
        row('Dana', '', 9), // unaffiliated: always last despite 9
        row('Eva', 'Sokol', 1),
        row('Čeněk', 'Sokol', 6),
      ]);

      expect(
        [for (final (header, _) in sections) header],
        ['Sokol', 'Šohaj', 'Veverky', 'Bez oddílu'],
      );
      expect(
        [
          for (final (_, members) in sections)
            [for (final r in members) r.displayName],
        ],
        [
          ['Čeněk', 'Eva'],
          ['Blanka'],
          ['Adam', 'Cyril'],
          ['Dana'],
        ],
      );
    });

    test('no unaffiliated rows means no Bez oddílu section', () {
      final sections = attendanceByClub([row('Adam', 'Veverky', 3)]);
      expect([for (final (header, _) in sections) header], ['Veverky']);
    });
  });

  group('closureRuns', () {
    DayOverride closed(int day, String reason) =>
        DayOverride(date: Day(2026, 7, day), closed: true, reason: reason);

    test('consecutive same-reason days fold into one run; a gap or a new '
        'reason starts another', () {
      final runs = closureRuns([
        // Deliberately unsorted input.
        closed(8, 'Malování drah'),
        closed(4, 'Dovolená'),
        closed(3, 'Dovolená'),
        closed(6, 'Malování drah'),
        closed(5, 'Malování drah'),
      ]);

      expect(
        [
          for (final run in runs) [for (final o in run) o.date.day],
        ],
        [
          [3, 4],
          [5, 6],
          [8],
        ],
      );
      expect(runs[0].first.reason, 'Dovolená');
      expect(runs[1].first.reason, 'Malování drah');
    });

    test('no closures yields no runs', () {
      expect(closureRuns(const []), isEmpty);
    });
  });
}
