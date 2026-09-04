import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';

void main() {
  test('no row means not linked', () {
    expect(CalendarLink.none.status, CalendarLinkStatus.notLinked);
    expect(CalendarLink.none.isLinked, isFalse);
    expect(CalendarLink.none.reminderMinutes, isEmpty);
  });

  test('parses a linked row', () {
    final link = CalendarLink.fromJson({
      'user_id': 'u1',
      'status': 'linked',
      'google_email': 'hrac@gmail.com',
      'last_error': null,
      'updated_at': '2026-09-03T07:30:00Z',
    });
    expect(link.status, CalendarLinkStatus.linked);
    expect(link.isLinked, isTrue);
    expect(link.googleEmail, 'hrac@gmail.com');
    expect(link.lastError, isNull);
    expect(link.updatedAt, DateTime.utc(2026, 9, 3, 7, 30));
  });

  test('a pending row keeps the failure reason for the retry prompt', () {
    final link = CalendarLink.fromJson({
      'status': 'pending',
      'google_email': 'hrac@gmail.com',
      'last_error': 'Kalendář se nepodařilo založit.',
    });
    expect(link.status, CalendarLinkStatus.pending);
    expect(link.isLinked, isFalse);
    expect(link.lastError, 'Kalendář se nepodařilo založit.');
  });

  test('a broken link keeps the reason for the re-link prompt', () {
    final link = CalendarLink.fromJson({
      'status': 'broken',
      'last_error': 'Google odvolal přístup.',
    });
    expect(link.status, CalendarLinkStatus.broken);
    expect(link.isLinked, isFalse);
    expect(link.lastError, 'Google odvolal přístup.');
  });

  test('reminder minutes parse sorted farthest-first; absence means none', () {
    expect(
      CalendarLink.fromJson({
        'status': 'linked',
        'reminder_minutes': [120, 1440],
      }).reminderMinutes,
      [1440, 120],
    );
    expect(
        CalendarLink.fromJson({'status': 'linked'}).reminderMinutes, isEmpty);
    expect(
      CalendarLink.fromJson({'status': 'linked', 'reminder_minutes': null})
          .reminderMinutes,
      isEmpty,
    );
  });

  test('offsets read as humans say them', () {
    expect(reminderOffsetLabel(0), 'V čase začátku');
    expect(reminderOffsetLabel(45), '45 min předem');
    expect(reminderOffsetLabel(120), '2 h předem');
    expect(reminderOffsetLabel(1440), '1 den předem');
    expect(reminderOffsetLabel(2880), '2 dny předem');
    expect(reminderOffsetLabel(4 * 1440), '4 dny předem');
    expect(reminderOffsetLabel(5 * 1440), '5 dní předem');
    expect(reminderOffsetLabel(7 * 1440), '7 dní předem');
    expect(reminderOffsetLabel(90), '90 min předem'); // no clean hour
  });

  test('summary joins from the farthest, empty reads as none', () {
    expect(remindersSummary(const []), 'Žádné');
    expect(remindersSummary(const [120, 2880]), '2 dny předem · 2 h předem');
    expect(remindersSummary(const [1440, 120]), '1 den předem · 2 h předem');
  });

  test('Google limits are mirrored: 5 reminders, 4 weeks ahead at most', () {
    expect(maxCalendarReminders, 5);
    expect(maxReminderMinutes, 28 * 24 * 60);
  });

  // A cleanly disconnected row stays behind as 'unlinked' (it keeps the
  // reminder preference); the card must read that as "offer Propojit".
  test('unlinked reads as not linked, the reminder preference survives', () {
    final link = CalendarLink.fromJson({
      'status': 'unlinked',
      'reminder_minutes': [1440],
    });
    expect(link.status, CalendarLinkStatus.notLinked);
    expect(link.isLinked, isFalse);
    expect(link.reminderMinutes, [1440]);
  });

  // The backend may grow states this build has never heard of; anything
  // unknown must read as "not linked" rather than blow up the profile card.
  test('unknown or missing status falls back to not linked', () {
    expect(CalendarLinkStatus.parse('kdovico'), CalendarLinkStatus.notLinked);
    expect(CalendarLinkStatus.parse(null), CalendarLinkStatus.notLinked);
    expect(CalendarLink.fromJson({'status': 'kdovico'}).status,
        CalendarLinkStatus.notLinked);
    expect(CalendarLink.fromJson(const {}).status,
        CalendarLinkStatus.notLinked);
  });

  test('fromJson reads the followed teams; absent means none', () {
    final link = CalendarLink.fromJson({
      'status': 'linked',
      'match_teams': ['SKK Veverky Brno A', 'KS Devítka Brno B'],
    });
    expect(link.matchTeams, ['SKK Veverky Brno A', 'KS Devítka Brno B']);
    expect(CalendarLink.fromJson({'status': 'linked'}).matchTeams, isEmpty);
  });

  test('matchTeamsSummary reads Žádné or the teams joined', () {
    expect(matchTeamsSummary(const []), 'Žádný tým');
    expect(matchTeamsSummary(const ['SKK Veverky Brno A', 'SKK Veverky Brno B']),
        'SKK Veverky Brno A · SKK Veverky Brno B');
  });
}
