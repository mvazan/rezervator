import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';

/// The pick list behind Moje týmy and the calendar's per-team routing.
void main() {
  PrioritySlot match({
    required String id,
    String home = '',
    String away = '',
    bool isAway = false,
    String? importKey,
    PrioritySlotType? type,
  }) =>
      PrioritySlot(
        id: id,
        date: Day(2026, 9, 12),
        startsAt: const HourMinute(18, 0),
        endsAt: const HourMinute(21, 0),
        type: type ?? PrioritySlot.fallbackMatchType,
        homeTeam: home,
        awayTeam: away,
        isAway: isAway,
        importKey: importKey,
      );

  List<String> teamsOf(List<PrioritySlot> slots) {
    final container = ProviderContainer(
      overrides: [prioritySlotsProvider.overrideWithValue(slots)],
    );
    addTearDown(container.dispose);
    return container.read(ourTeamsProvider);
  }

  test('our side of every imported match, Czech-sorted', () {
    expect(
      teamsOf([
        match(
            id: 'm1',
            home: 'SKK Veverky Brno A',
            away: 'KK MS Brno D',
            importKey: 'rozpis:KP1 Sever:1:SKK Veverky Brno A – KK MS Brno D'),
        match(
            id: 'm2',
            home: 'KK Blansko B',
            away: 'TJ Sokol Husovice C',
            isAway: true,
            importKey: 'rozpis:KP1 Sever:2:KK Blansko B – TJ Sokol Husovice C'),
        match(
            id: 'm3',
            home: 'Čáslavská',
            away: 'KK MS Brno D',
            importKey: 'rozpis:KP1 Sever:3:Čáslavská – KK MS Brno D'),
      ]),
      ['Čáslavská', 'SKK Veverky Brno A', 'TJ Sokol Husovice C'],
      reason: 'home team of a home match, away team of an away one',
    );
  });

  // The complaint this rule exists for: "Husky – přátelák" and
  // "PMN – 1.turnaj" are events the admin typed in, not fixtures, and their
  // halves are not teams anybody follows.
  test('a match entered by hand names no teams while the schedule is there',
      () {
    final teams = teamsOf([
      match(
          id: 'm1',
          home: 'TJ Sokol Brno IV',
          away: 'SK Kuželky Dubňany',
          importKey:
              'rozpis:JM divize:1:TJ Sokol Brno IV – SK Kuželky Dubňany'),
      match(id: 'h', home: 'Husky', away: 'přátelák'),
      match(id: 'p', home: 'PMN', away: '1.turnaj'),
    ]);
    expect(teams, ['TJ Sokol Brno IV']);
  });

  test('…but an alley with no imported match at all still gets a list', () {
    expect(
      teamsOf([
        match(id: 'h', home: 'Husky', away: 'přátelák'),
        match(id: 'a', home: 'KK Cizí', away: 'Naši', isAway: true),
      ]),
      ['Husky', 'Naši'],
      reason: 'without a schedule, hand-entered matches are all there is',
    );
  });

  test('the youth squad is its own team once the import marks it', () {
    final teams = teamsOf([
      match(
          id: 'a',
          home: 'TJ Sokol Husovice',
          away: 'TJ Odry',
          importKey: 'rozpis:1.KLM:3:TJ Sokol Husovice – TJ Odry'),
      match(
          id: 'd',
          home: 'TJ Sokol Husovice (dorost)',
          away: 'TJ Sokol Šanov',
          importKey:
              'rozpis:KP dorostu:5:TJ Sokol Husovice (dorost) – TJ Sokol Šanov'),
    ]);
    expect(teams, ['TJ Sokol Husovice', 'TJ Sokol Husovice (dorost)']);
  });

  test('úklid children and blockages are not matches, empty names are not '
      'teams', () {
    const blockage = PrioritySlotType(id: 't-uklid', name: 'Úklid', builtin: true);
    final teams = teamsOf([
      match(
          id: 'm1',
          home: 'SKK Veverky Brno A',
          away: 'KK MS Brno D',
          importKey: 'rozpis:KP1 Sever:1:SKK Veverky Brno A – KK MS Brno D'),
      match(id: 'u1', type: blockage, importKey: 'rozpis:x'),
      match(id: 'e1', home: '', away: 'Kdosi', importKey: 'rozpis:y'),
    ]);
    expect(teams, ['SKK Veverky Brno A']);
  });
}
