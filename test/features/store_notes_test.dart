import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/features/profile/changelog_data.dart';
import 'package:rezervator/features/profile/store_notes.dart';

void main() {
  group('firstSentence', () {
    test('cuts at the first full stop that ends a word', () {
      expect(firstSentence('Kratší. A zbytek věty.'), 'Kratší.');
      expect(firstSentence('Otázka? Odpověď.'), 'Otázka?');
    });

    test('a version, a date or a percentage is not a full stop', () {
      expect(firstSentence('Verze 1.2.2 je venku. Detail.'),
          'Verze 1.2.2 je venku.');
      expect(firstSentence('Zápas 15. 9. se hraje doma. Detail.'),
          'Zápas 15. 9. se hraje doma.');
      expect(firstSentence('Písmo až 130 %. Detail.'), 'Písmo až 130 %.');
    });

    test('a sentence that starts with a quote or a digit is not a break — '
        'keeping more text is the safe direction', () {
      expect(firstSentence('Nejdřív tohle. 130 % je znát.'),
          'Nejdřív tohle. 130 % je znát.');
    });

    test('text without a break survives whole', () {
      expect(firstSentence('Jedna věta bez tečky'), 'Jedna věta bez tečky');
    });
  });

  group('storeNotes', () {
    test('short enough keeps every word', () {
      final text = storeNotes(['První věc.', 'Druhá věc.']);
      expect(text, '• První věc.\n• Druhá věc.');
    });

    test('over the limit drops to first sentences, keeping every bullet', () {
      final changes = [
        for (var i = 0; i < 5; i++)
          'Novinka $i. ${'Podrobnost, kterou lze oželet. ' * 6}',
      ];
      final text = storeNotes(changes);
      expect(text.length, lessThanOrEqualTo(500));
      for (var i = 0; i < 5; i++) {
        expect(text, contains('Novinka $i.'));
      }
      expect(text, isNot(contains('Podrobnost')));
    });

    test('when first sentences still overflow, the tail falls off — whole '
        'sentences, never a half one', () {
      final changes = [
        for (var i = 0; i < 12; i++) 'Delší novinka číslo $i o něčem užitečném.',
      ];
      final text = storeNotes(changes);
      expect(text.length, lessThanOrEqualTo(500));
      expect(text, contains('číslo 0'));
      expect(text, isNot(contains('číslo 11')));
      expect(text.endsWith('.'), isTrue, reason: 'no dangling fragment');
      expect(text, isNot(contains('…')));
    });

    test('a single bullet longer than the whole budget is cut on a word', () {
      final text = storeNotes(['Slovo ' * 200]);
      expect(text.length, lessThanOrEqualTo(500));
      expect(text.endsWith('…'), isTrue);
      expect(text, isNot(contains('Slov…')), reason: 'cut between words');
    });

    test('every released changelog entry fits, as written', () {
      for (final r in appChangelog.where((r) => r.version != null)) {
        expect(storeNotes(r.changes).length, lessThanOrEqualTo(500),
            reason: 'verze ${r.version}');
      }
    });

    test('the newest release needs no shortening — the entry is written to '
        'fit, and this is the reminder when it stops fitting', () {
      final newest = appChangelog.firstWhere((r) => r.version != null);
      final full = newest.changes.map((c) => '• $c').join('\n');
      expect(storeNotes(newest.changes), full,
          reason: 'verze ${newest.version} by se ořezala; zkrať ji v '
              'changelog_data.dart, ať je ve storu přesně to, co je v appce');
    });
  });
}
