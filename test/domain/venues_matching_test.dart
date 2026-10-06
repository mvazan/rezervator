import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/results.dart';

void main() {
  group('venuesMatching', () {
    Venue venue(String slug, String name,
            {String? address, List<String> clubs = const []}) =>
        Venue(
          id: slug,
          slug: slug,
          name: name,
          address: address,
          clubs: clubs,
          fetchedAt: DateTime.utc(2026, 9, 20),
        );

    final venues = [
      venue('brno-iv', 'TJ Sokol Brno IV',
          address: 'Štolcova 551/8, 61800 Brno',
          clubs: ['TJ Sokol Brno IV', 'SKK Veverky Brno']),
      venue('husovice', 'TJ Sokol Husovice', address: 'Dukelská 1, Brno'),
      venue('znojmo', 'KK Znojmo'),
    ];

    List<String> slugs(String q) =>
        [for (final v in venuesMatching(venues, q)) v.slug];

    test('a blank query keeps all, Czech-sorted by name', () {
      expect(slugs(''), ['znojmo', 'brno-iv', 'husovice']);
      expect(slugs('  '), hasLength(3));
    });

    test('words of the name in any order, not just one stretch', () {
      expect(slugs('sokol iv'), ['brno-iv']);
      expect(slugs('iv brno'), ['brno-iv']);
      expect(slugs('sokol'), ['brno-iv', 'husovice']);
    });

    test('words across the name, the address and the clubs', () {
      expect(slugs('stolcova brno'), ['brno-iv'], reason: 'the address');
      expect(slugs('sokol dukelska'), ['husovice'], reason: 'name + address');
      expect(slugs('husovice veverky'), isEmpty);
      expect(slugs('znojmo praha'), isEmpty);
    });

    test('accents do not count', () {
      expect(slugs('ŠTOLCOVA'), ['brno-iv']);
    });
  });
}
