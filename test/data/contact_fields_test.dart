import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';

/// Api.updateMyContact writes exactly these columns of the caller's own
/// profiles row (0048) — nothing it was not given.
void main() {
  test('only the fields passed are written', () {
    expect(contactFields(phone: '+420777123456'), {'phone': '+420777123456'});
    expect(contactFields(showEmail: false), {'show_email': false});
    expect(contactFields(showPhone: true), {'show_phone': true});
    expect(
      contactFields(showEmail: true, showPhone: false),
      {'show_email': true, 'show_phone': false},
    );
    expect(contactFields(), isEmpty);
  });

  test('an empty phone clears the number', () {
    expect(contactFields(phone: ''), {'phone': null});
  });
}
