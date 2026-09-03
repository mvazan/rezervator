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
    expect(friendlyDbError(Exception('switch_home_first')),
        'Nejdřív se přepni zpět domů, pak kuželnu zamítni.');
    expect(friendlyDbError(Exception('rental_exception_invalid')),
        'Výjimku lze zadat jen na den pravidelného pronájmu.');
    expect(friendlyDbError(Exception('player_has_history')),
        'Hráč už má rezervace — sluč ho s účtem, nebo ho nech být.');
    expect(friendlyDbError(Exception('invalid_merge')),
        'Tyhle dva profily nejde sloučit.');
    expect(friendlyDbError(Exception('placeholder_no_account')),
        'Hráč bez účtu nemůže být správce ani kiosk.');
    expect(friendlyDbError(Exception('unknown_player')),
        'Tenhle hráč už neexistuje.');
    expect(friendlyDbError(Exception('something else')),
        startsWith('Něco se nepovedlo.'));
  });

  test('initialsOf takes first letters of the first two words, uppercased',
      () {
    expect(initialsOf('Ján Novák'), 'JN');
    expect(initialsOf('Cher'), 'CH');
    expect(initialsOf(''), '?');
  });
}
