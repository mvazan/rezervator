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
    expect(friendlyDbError(Exception('unknown_rental')),
        'Tenhle pronájem už neexistuje.');
    expect(friendlyDbError(Exception('rental_group_invalid')),
        'Termín nejde přiřadit k tomuhle pronájmu.');
    expect(friendlyDbError(Exception('something else')),
        startsWith('Něco se nepovedlo.'));
  });

  test('public overview / federation slug errors (shared code)', () {
    expect(
      friendlyDbError(Exception('invalid_slug')),
      'Adresa kuželny smí mít jen malá písmena bez diakritiky, číslice '
          'a pomlčky.',
    );
    expect(friendlyDbError(Exception('slug_taken')), 'Tuhle adresu už má jiná kuželna.');
  });

  test('federation sync errors (0045)', () {
    expect(friendlyDbError(Exception('federation_not_configured')),
        'Nejdřív ulož kuželnu z výsledkového servisu.');
    expect(friendlyDbError(Exception('federation_disabled')),
        'Zapni nejdřív automatické stahování.');
    expect(friendlyDbError(Exception('team_name_taken')),
        'Tým s tímto názvem už existuje.');
    expect(friendlyDbError(Exception('empty_name')), 'Název nesmí být prázdný.');
  });

  test('group errors (0044)', () {
    expect(friendlyDbError(Exception('member_at_limit')),
        'Člen skupiny už má maximální počet rezervací.');
    expect(friendlyDbError(Exception('already_member')), 'Už je ve tvé skupině.');
    expect(friendlyDbError(Exception('already_invited')),
        'Pozvánku už má — čeká se, až ji přijme.');
    expect(friendlyDbError(Exception('unknown_invite')), 'Tahle pozvánka už neplatí.');
    expect(friendlyDbError(Exception('already_in_group')),
        'Už jsi v jiné skupině — nejdřív z ní odejdi.');
    expect(friendlyDbError(Exception('member_at_limit')),
        isNot('Máš už maximální počet rezervací.'));
  });

  test('initialsOf takes first letters of the first two words, uppercased',
      () {
    expect(initialsOf('Ján Novák'), 'JN');
    expect(initialsOf('Cher'), 'CH');
    expect(initialsOf(''), '?');
  });
}
