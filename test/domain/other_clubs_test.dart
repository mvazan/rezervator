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
}
