import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/slug.dart';

void main() {
  group('suggestSlug', () {
    test('folds diacritics, lower-cases and hyphenates', () {
      expect(suggestSlug('Kuželna Sokol Brno'), 'kuzelna-sokol-brno');
      expect(suggestSlug('TJ  Lokomotiva – Ústí n/L'), 'tj-lokomotiva-usti-n-l');
    });
    test('trims hyphens at both ends', () {
      expect(suggestSlug(' „Veverky" '), 'veverky');
    });
    test('caps at 40 characters without a trailing hyphen', () {
      final s = suggestSlug('Kuželkářský oddíl Tělovýchovné jednoty Lokomotiva');
      expect(s.length, lessThanOrEqualTo(40));
      expect(s.endsWith('-'), isFalse);
      expect(slugPattern.hasMatch(s), isTrue);
    });
    test('too short a name suggests nothing', () {
      expect(suggestSlug('Ž'), '');
      expect(suggestSlug('!!'), '');
    });
  });

  group('slugPattern mirrors the DB check', () {
    test('accepts', () {
      // 'abc' is the 3-character minimum the DB check still accepts.
      for (final s in ['abc', 'kuzelna-a', 'a1-b2', 'x' * 40]) {
        expect(slugPattern.hasMatch(s), isTrue, reason: s);
      }
    });
    test('rejects', () {
      for (final s in ['a', 'ab', '-abc', 'abc-', 'Abc', 'a_b', 'kuželna', 'x' * 41]) {
        expect(slugPattern.hasMatch(s), isFalse, reason: s);
      }
    });
  });

  group('the kuželna on the ČKA site (0046)', () {
    test('venueSlugPattern mirrors set_federation_sync\'s check', () {
      for (final s in ['a', 'kk2', 'tj-sokol-brno-iv']) {
        expect(venueSlugPattern.hasMatch(s), isTrue, reason: s);
      }
      for (final s in ['', 'A', 'a-', '-a', 'a--b', 'a_b', 'kuželna']) {
        expect(venueSlugPattern.hasMatch(s), isFalse, reason: s);
      }
    });

    test('takes the slug or the page\'s whole address, host optional', () {
      for (final input in [
        'tj-sokol-brno-iv',
        '  TJ-Sokol-Brno-IV ',
        'tj-sokol-brno-iv/',
        'https://vysledky.kuzelky.cz/detail-kuzelny/tj-sokol-brno-iv',
        'vysledky.kuzelky.cz/detail-kuzelny/tj-sokol-brno-iv/',
        'https://vysledky.kuzelky.cz/detail-kuzelny/tj-sokol-brno-iv?tab=info#mapa',
        '/detail-kuzelny/tj-sokol-brno-iv',
      ]) {
        expect(venueSlugFromInput(input), 'tj-sokol-brno-iv', reason: input);
      }
    });

    test('null for anything that is no kuželna slug', () {
      for (final input in [
        '',
        '   ',
        'https://vysledky.kuzelky.cz/detail-klubu/ks-devitka-brno',
        'https://vysledky.kuzelky.cz/detail-kuzelny/',
        'vysledky.kuzelky.cz',
        'detail-kuzelny/a/b',
        'Kuželna Brno',
        'tj--sokol',
      ]) {
        expect(venueSlugFromInput(input), isNull, reason: input);
      }
    });

    test('the inline error: nothing typed, or no kuželna', () {
      expect(venueSlugInputError('tj-sokol-brno-iv'), isNull);
      expect(venueSlugInputError('  '), 'Vlož adresu stránky kuželny.');
      expect(
        venueSlugInputError(
            'https://vysledky.kuzelky.cz/detail-klubu/ks-devitka-brno'),
        'Tohle není adresa kuželny — zkopíruj adresu stránky, která '
        'obsahuje /detail-kuzelny/.',
      );
    });
  });
}
