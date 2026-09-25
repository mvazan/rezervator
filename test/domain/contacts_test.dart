import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/contacts.dart';
import 'package:rezervator/domain/models.dart';

void main() {
  group('contactsMatching', () {
    const contacts = [
      Contact(id: 'z', displayName: 'Zdeněk Zelený'),
      Contact(
        id: 's',
        displayName: 'Šárka Svobodová',
        nick: 'Šára',
        clubName: 'KK Slovan Rosice',
      ),
      Contact(id: 'c', displayName: 'Čeněk Černý', clubName: 'TJ Sokol'),
      Contact(id: 'h', displayName: 'Chalupa Jan'),
      Contact(id: 'a', displayName: 'Adam Admin', nick: 'Áďa'),
    ];

    List<String> names(List<Contact> list) =>
        [for (final c in list) c.displayName];

    test('an empty query keeps everyone, Czech-sorted', () {
      expect(names(contactsMatching(contacts, '')), [
        'Adam Admin',
        'Čeněk Černý',
        'Chalupa Jan',
        'Šárka Svobodová',
        'Zdeněk Zelený',
      ]);
      expect(names(contactsMatching(contacts, '   ')), hasLength(5));
    });

    test('the name, accent- and case-insensitive', () {
      expect(names(contactsMatching(contacts, 'cerny')), ['Čeněk Černý']);
      expect(names(contactsMatching(contacts, 'ŠÁRKA')), ['Šárka Svobodová']);
    });

    test('the board nick', () {
      expect(names(contactsMatching(contacts, 'sara')), ['Šárka Svobodová']);
    });

    test('the club', () {
      expect(names(contactsMatching(contacts, 'rosice')), ['Šárka Svobodová']);
      expect(names(contactsMatching(contacts, 'sokol')), ['Čeněk Černý']);
    });

    test('nobody matches', () {
      expect(contactsMatching(contacts, 'Havířov'), isEmpty);
    });
  });
}
