import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/other_clubs.dart';

void main() {
  Venue venue(String id, List<String> clubs) => Venue(
    id: id,
    slug: id,
    name: id,
    clubs: clubs,
    fetchedAt: DateTime(2026, 10, 17),
  );

  test('the clubs at the alleys our teams play at and those with a nickname, '
      'each once, Czech-sorted, without our own', () {
    final names = otherClubNames(
      venues: [
        venue('brno', [
          'TJ Sokol Brno IV',
          'SKK Veverky Brno',
          ' TJ Sokol Husovice ',
        ]),
        venue('blansko', ['KK Blansko', 'TJ Sokol Husovice']),
      ],
      clubs: [
        const Club(id: 's', name: 'Sokol IV', siteName: 'TJ Sokol Brno IV'),
        const Club(id: 'v', name: 'SKK Veverky Brno'),
      ],
      nicknames: const [
        ClubNickname(id: 'c', name: 'Č. Budějovice', nickname: 'Budějky'),
        ClubNickname(id: 'h', name: 'TJ Sokol Husovice', nickname: 'Husovice'),
      ],
    );
    expect(names, ['Č. Budějovice', 'KK Blansko', 'TJ Sokol Husovice']);
  });

  test('no federation data: only the clubs given a nickname by hand', () {
    expect(
      otherClubNames(
        venues: const [],
        clubs: const [],
        nicknames: const [
          ClubNickname(
            id: 'h',
            name: 'TJ Sokol Husovice',
            nickname: 'Husovice',
          ),
        ],
      ),
      ['TJ Sokol Husovice'],
    );
  });

  test('the opponents of our matches by their team without its letter, '
      'each spelling once; our own teams and clubs left out', () {
    PrioritySlot match(String home, String away, {bool away_ = false}) =>
        PrioritySlot(
          id: '$home-$away',
          date: Day(2026, 10, 17),
          startsAt: const HourMinute(10, 0),
          endsAt: const HourMinute(13, 0),
          type: PrioritySlot.fallbackMatchType,
          homeTeam: home,
          awayTeam: away,
          isAway: away_,
        );
    final names = otherClubNames(
      venues: const [],
      clubs: const [Club(id: 'v', name: 'SKK Veverky Brno')],
      nicknames: const [],
      matches: [
        match('SKK Veverky Brno A', 'KK Moravská Slavia Brno B'),
        match('KK Moravská Slávia Brno G', 'SKK Veverky Brno C', away_: true),
        match('SKK Veverky Brno A', 'Viktoria Zlín'),
        // A derby: both ours.
        match('SKK Veverky Brno A', 'SKK Veverky Brno C'),
        // An úklid or a blockage is no opponent.
        PrioritySlot(
          id: 'b',
          date: Day(2026, 10, 18),
          startsAt: const HourMinute(9, 0),
          endsAt: const HourMinute(10, 0),
          type: const PrioritySlotType(id: 't', name: 'Brigáda'),
          awayTeam: 'Brigádníci B',
        ),
      ],
      ourTeams: const ['SKK Veverky Brno A', 'SKK Veverky Brno C'],
    );
    expect(names, [
      'KK Moravská Slavia Brno',
      'KK Moravská Slávia Brno',
      'Viktoria Zlín',
    ]);
  });
}
