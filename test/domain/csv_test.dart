import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/csv.dart';

void main() {
  test('starts with BOM, joins with ; and CRLF', () {
    final csv = toCsv([
      ['Hráč', 'Klub', 'Počet'],
      ['Ján Novák', 'KK Praha', '4'],
    ]);
    expect(csv.startsWith('﻿'), isTrue);
    expect(csv, '﻿Hráč;Klub;Počet\r\nJán Novák;KK Praha;4');
  });

  test('quotes fields with separators and doubles quotes', () {
    expect(toCsv([
      ['a;b', 'say "hi"', 'line\nbreak', 'plain'],
    ]), '﻿"a;b";"say ""hi""";"line\nbreak";plain');
  });
}
