import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart';

void main() {
  test('friendlyDbError maps schema exception codes to Czech copy', () {
    expect(friendlyDbError(Exception('PostgrestException: slot_taken')),
        'Termín je už obsazený.');
    expect(friendlyDbError(Exception('limit_reached')),
        'Máš už maximální počet rezervací.');
    expect(friendlyDbError(Exception('too_late')),
        'Trénink už začal — rezervaci může zrušit jen správce.');
    expect(friendlyDbError(Exception('something else')),
        startsWith('Něco se nepovedlo.'));
  });
}
