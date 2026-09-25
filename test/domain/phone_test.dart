import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/phone.dart';

void main() {
  group('normalizePhone', () {
    test('a bare Czech nine-digit number gets +420', () {
      expect(normalizePhone('777123456'), '+420777123456');
      expect(normalizePhone('777 123 456'), '+420777123456');
    });

    test('+420 with spaces, dashes, dots or brackets', () {
      expect(normalizePhone('+420 777 123 456'), '+420777123456');
      expect(normalizePhone(' +420-777-123-456 '), '+420777123456');
      expect(normalizePhone('+420 777.123.456'), '+420777123456');
      expect(normalizePhone('(+420) 777 123 456'), '+420777123456');
    });

    test('a leading 00 becomes +', () {
      expect(normalizePhone('00420 777 123 456'), '+420777123456');
      expect(normalizePhone('0049 30 1234567'), '+49301234567');
    });

    test('a foreign number stays as typed, digits only', () {
      expect(normalizePhone('+49 30 1234567'), '+49301234567');
      expect(normalizePhone('+421 905 123 456'), '+421905123456');
    });

    test('junk, too short and too long are refused', () {
      expect(normalizePhone(''), isNull);
      expect(normalizePhone('   '), isNull);
      expect(normalizePhone('abc'), isNull);
      expect(normalizePhone('777 12a 456'), isNull);
      expect(normalizePhone('12345'), isNull);
      expect(normalizePhone('+420 12'), isNull);
      expect(normalizePhone('77712345'), isNull, reason: 'eight digits, no +');
      expect(normalizePhone('+4207771234567890'), isNull, reason: '16 digits');
      expect(normalizePhone('+0777123456'), isNull, reason: 'E.164 never +0');
    });

    test('every result passes the database rule', () {
      for (final input in ['777123456', '+49 30 1234567', '00420777123456']) {
        expect(e164Pattern.hasMatch(normalizePhone(input)!), isTrue);
      }
    });
  });

  group('formatPhone', () {
    test('a Czech number reads in threes', () {
      expect(formatPhone('+420777123456'), '+420 777 123 456');
    });

    test('any other number shows as stored', () {
      expect(formatPhone('+49301234567'), '+49301234567');
      expect(formatPhone('+421905123456'), '+421905123456');
    });
  });

  group('whatsappUri', () {
    test('wa.me with the digits, no plus', () {
      expect(whatsappUri('+420777123456').toString(),
          'https://wa.me/420777123456');
      expect(whatsappUri('+49301234567').toString(),
          'https://wa.me/49301234567');
    });
  });

  test('the invalid-phone copy', () {
    expect(invalidPhoneMessage,
        'Telefon nemá správný tvar — třeba +420 777 123 456.');
  });
}
