import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/palette.dart';

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

  test('matchTeamsSummary reads Žádné or the teams joined', () {
    expect(matchTeamsSummary(const []), 'Žádný tým');
    expect(matchTeamsSummary(const ['SKK Veverky Brno A', 'SKK Veverky Brno B']),
        'SKK Veverky Brno A · SKK Veverky Brno B');
  });

  // -------------------------------------------------------------------------
  // 0032: the second calendar, event colours and calendar_teams
  // -------------------------------------------------------------------------

  group('CalendarSlot', () {
    test('names are the DB values', () {
      expect(CalendarSlot.primary.name, 'primary');
      expect(CalendarSlot.secondary.name, 'secondary');
    });

    test('parses the two known values', () {
      expect(CalendarSlot.parse('primary'), CalendarSlot.primary);
      expect(CalendarSlot.parse('secondary'), CalendarSlot.secondary);
    });

    // Same fallback the backend applies to a missing/unknown calendar
    // (calendar-manage, set_calendar_teams_for): default to primary rather
    // than blow up.
    test('unknown or missing reads as primary', () {
      expect(CalendarSlot.parse(null), CalendarSlot.primary);
      expect(CalendarSlot.parse('kdovico'), CalendarSlot.primary);
    });
  });

  group('CalendarTeam', () {
    test('fromJson reads team, calendar and colour', () {
      final team = CalendarTeam.fromJson({
        'team': 'SKK Veverky Brno A',
        'calendar': 'secondary',
        'color_id': 7,
      });
      expect(team.team, 'SKK Veverky Brno A');
      expect(team.calendar, CalendarSlot.secondary);
      expect(team.colorId, 7);
    });

    test('a missing calendar defaults to primary, a missing colour to null',
        () {
      final team = CalendarTeam.fromJson({'team': 'SKK Veverky Brno A'});
      expect(team.calendar, CalendarSlot.primary);
      expect(team.colorId, isNull);
    });

    test('a null color_id stays null (no colour, not zero)', () {
      final team = CalendarTeam.fromJson({
        'team': 'SKK Veverky Brno A',
        'calendar': 'primary',
        'color_id': null,
      });
      expect(team.colorId, isNull);
    });

    test('toJson matches the calendar-manage teams payload exactly', () {
      const team = CalendarTeam(
        team: 'SKK Veverky Brno A',
        calendar: CalendarSlot.secondary,
        colorId: 3,
      );
      expect(team.toJson(), {
        'team': 'SKK Veverky Brno A',
        'calendar': 'secondary',
        'color_id': 3,
      });
    });

    test('the constructor defaults to primary with no colour', () {
      const team = CalendarTeam(team: 'SKK Veverky Brno A');
      expect(team.calendar, CalendarSlot.primary);
      expect(team.colorId, isNull);
    });
  });

  group('CalendarLink — second calendar fields (0032)', () {
    test('absent fields default to off/empty/no colour', () {
      final link = CalendarLink.fromJson({'status': 'linked'});
      expect(link.secondaryEnabled, isFalse);
      expect(link.reminderMinutesSecondary, isEmpty);
      expect(link.trainingColorId, isNull);
    });

    test('reads secondary_enabled, reminders and training colour', () {
      final link = CalendarLink.fromJson({
        'status': 'linked',
        'secondary_enabled': true,
        'reminder_minutes_secondary': [60, 1440],
        'training_color_id': 5,
      });
      expect(link.secondaryEnabled, isTrue);
      // Same farthest-first order as the primary reminders.
      expect(link.reminderMinutesSecondary, [1440, 60]);
      expect(link.trainingColorId, 5);
    });

    // match_teams is a deprecated mirror (kept only until build 1.2.1 stops
    // reading it); calendar_teams is the truth from here on, so parsing
    // must not even look at the field any more.
    test('never reads match_teams — calendar_teams is the truth now', () {
      final link = CalendarLink.fromJson({
        'status': 'linked',
        'match_teams': ['SKK Veverky Brno A'],
      });
      expect(link.status, CalendarLinkStatus.linked); // just doesn't blow up
    });
  });

  group('googleEventColors', () {
    test('has all eleven of Google\'s fixed event colours, ids 1-11 in order',
        () {
      expect(googleEventColors, hasLength(11));
      expect(googleEventColors.map((c) => c.$1), List.generate(11, (i) => i + 1));
    });

    test('every id and every Czech name is unique', () {
      expect(googleEventColors.map((c) => c.$1).toSet(), hasLength(11));
      expect(googleEventColors.map((c) => c.$2).toSet(), hasLength(11));
    });

    // Spot-check against the design doc's table (verbatim Czech names).
    test('matches the design doc for the first and last entries', () {
      expect(googleEventColors.first, (1, 'Levandulová', const Color(0xFF7986CB)));
      expect(googleEventColors.last, (11, 'Rajčatová', const Color(0xFFD50000)));
      final basil = googleEventColors.firstWhere((c) => c.$1 == 10);
      expect(basil.$2, 'Bazalková');
      expect(basil.$3, const Color(0xFF0B8043));
    });
  });
}
