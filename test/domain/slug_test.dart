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
      for (final s in ['abc', 'kuzelna-a', 'a1-b2', 'x' * 40]) {
        expect(slugPattern.hasMatch(s), isTrue, reason: s);
      }
    });
    test('rejects', () {
      for (final s in ['ab', '-abc', 'abc-', 'Abc', 'a_b', 'kuželna', 'x' * 41]) {
        expect(slugPattern.hasMatch(s), isFalse, reason: s);
      }
    });
  });
}
