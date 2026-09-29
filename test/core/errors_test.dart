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

  test('public overview slug errors', () {
    expect(friendlyDbError(Exception('invalid_slug')),
        'Adresa smí mít 3–40 znaků: malá písmena, číslice a pomlčky.');
    expect(friendlyDbError(Exception('slug_taken')), 'Tuhle adresu už má jiná kuželna.');
  });

  test('federation sync errors (0045) — invalid_venue_slug has its own copy, '
      'distinct from the unrelated invalid_slug (0043) despite the shared '
      'substring', () {
    expect(
      friendlyDbError(Exception('invalid_venue_slug')),
      'Adresa kuželny smí mít jen malá písmena bez diakritiky, číslice '
          'a pomlčky.',
    );
    expect(
      friendlyDbError(Exception('invalid_slug')),
      isNot(contains('diakritiky')),
    );
    expect(friendlyDbError(Exception('federation_not_configured')),
        'Nejdřív ulož kuželnu z výsledkového servisu.');
    expect(friendlyDbError(Exception('federation_disabled')),
        'Zapni nejdřív automatické stahování.');
    expect(friendlyDbError(Exception('team_name_taken')),
        'Tým s tímto názvem už existuje.');
    expect(friendlyDbError(Exception('empty_name')), 'Název nesmí být prázdný.');
    expect(
      friendlyDbError(Exception('new row for relation "teams" violates check '
          'constraint "teams_name_check"')),
      'Název týmu smí mít nejvýš 80 znaků.',
    );
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

  test('phone errors (0048) — the server code and the table constraint', () {
    const copy = 'Telefon nemá správný tvar — třeba +420 777 123 456.';
    expect(friendlyDbError(Exception('invalid_phone')), copy);
    expect(
      friendlyDbError(Exception('new row for relation "profiles" violates '
          'check constraint "profiles_phone_check"')),
      copy,
    );
    expect(friendlyDbError(Exception('not_allowed')),
        'Na tohle nemáš oprávnění.');
  });

  test('canteen duty errors (0050)', () {
    expect(friendlyDbError(Exception('duty_overlap')),
        'Služba se překrývá s jinou.');
    expect(friendlyDbError(Exception('invalid_range')),
        '„Do“ musí být po „Od“.');
    expect(friendlyDbError(Exception('duty_too_long')),
        'Služba může mít nejvýše 62 dní.');
    expect(friendlyDbError(Exception('unknown_period')),
        'Tahle služba už neexistuje.');
    expect(friendlyDbError(Exception('season_order')),
        'Nová sezóna musí začínat po té současné.');
    expect(friendlyDbError(Exception('not_newest')),
        'Vrátit jde jen poslední sezónu.');
    expect(friendlyDbError(Exception('player_at_limit')),
        'Hráč už má maximální počet rezervací.');
    expect(friendlyDbError(Exception('invalid_days')),
        'Počet dní musí být 1–31.');
    expect(friendlyDbError(Exception('player_has_history')),
        'Hráč už má rezervace — sluč ho s účtem, nebo ho nech být.');
    expect(friendlyDbError(Exception('empty_name')), 'Název nesmí být prázdný.');
    expect(
      friendlyDbError(Exception('new row for relation "duty_periods" violates '
          'check constraint "duty_periods_note_check"')),
      'Poznámka smí mít nejvýš 80 znaků.',
    );
    expect(
      friendlyDbError(Exception('new row for relation "duty_seasons" violates '
          'check constraint "duty_seasons_name_check"')),
      'Název sezóny smí mít nejvýš 40 znaků.',
    );
  });

  test('messages errors (0051)', () {
    expect(friendlyDbError(Exception('no_recipients')), 'Nikdo nemá rezervaci.');
    expect(friendlyDbError(Exception('nobody_on_duty')),
        'Dnes nikdo neslouží — napiš správci.');
    expect(friendlyDbError(Exception('title_required')), 'Vyplň nadpis.');
    expect(friendlyDbError(Exception('body_required')), 'Vyplň zprávu.');
    expect(friendlyDbError(Exception('body_too_long')), 'Zpráva je moc dlouhá.');
    expect(friendlyDbError(Exception('title_too_long')), 'Nadpis je moc dlouhý.');
    // The reply has no RPC: PostgREST's refusal names the CHECK constraint.
    expect(
        friendlyDbError(Exception('new row for relation "message_recipients" '
            'violates check constraint "message_recipients_reply_check"')),
        'Odpověď je moc dlouhá.');
    expect(friendlyDbError(Exception('unknown_message')), 'Zpráva už neexistuje.');
    expect(friendlyDbError(Exception('invalid_audience')), 'Neplatný typ zprávy.');
    expect(friendlyDbError(Exception('invalid_kind')), 'Neplatný typ zprávy.');
    // Kept from 0050, the text the spec wants for a removed block.
    expect(friendlyDbError(Exception('unknown_block')),
        'Tenhle blok už neplatí — mrkni na aktuální rozvrh.');
  });

  test('not_allowed after the duty ended reads as the end of the duty', () {
    const ended = 'Služba skončila — tohle teď může jen správce.';
    final refused = Exception('PostgrestException(message: not_allowed, '
        'code: P0001)');
    expect(friendlyDbError(refused, wasOnDuty: true), ended);
    // Everywhere else the plain refusal stays.
    expect(friendlyDbError(refused), 'Na tohle nemáš oprávnění.');
    expect(friendlyDbError(refused, wasOnDuty: false),
        'Na tohle nemáš oprávnění.');
    // Only not_allowed changes; the duty's other refusals keep their copy.
    expect(friendlyDbError(Exception('date_past'), wasOnDuty: true),
        'Tenhle termín už je v minulosti.');
    expect(friendlyDbError(Exception('player_at_limit'), wasOnDuty: true),
        'Hráč už má maximální počet rezervací.');
    // Still a plain `String Function(Object)` for tryAction's errorText.
    final String Function(Object) errorText = friendlyDbError;
    expect(errorText(refused), 'Na tohle nemáš oprávnění.');
  });

  test('initialsOf takes first letters of the first two words, uppercased',
      () {
    expect(initialsOf('Ján Novák'), 'JN');
    expect(initialsOf('Cher'), 'CH');
    expect(initialsOf(''), '?');
  });
}
