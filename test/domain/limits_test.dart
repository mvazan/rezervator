import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/limits.dart';

void main() {
  group('Limits', () {
    test('carry the bounds the admin and registration forms enforce', () {
      expect(Limits.laneCount, (min: 1, max: 12));
      expect(Limits.horizonDays, (min: 1, max: 90));
      expect(Limits.maxActiveReservations, (min: 1, max: 50));
      expect(Limits.prepMinutes, (min: 0, max: 240));
      expect(Limits.closureSpanDays, 92);
      expect(Limits.nickLength, 14);
    });
  });

  group('validateScheduleSettings', () {
    String? validate({
      int laneCount = 4,
      int horizonDays = 14,
      int maxReservations = 3,
    }) => validateScheduleSettings(
      laneCount: laneCount,
      horizonDays: horizonDays,
      maxReservations: maxReservations,
    );

    test('the defaults and every inclusive bound pass', () {
      expect(validate(), isNull);
      expect(validate(laneCount: 1), isNull);
      expect(validate(laneCount: 12), isNull);
      expect(validate(horizonDays: 1), isNull);
      expect(validate(horizonDays: 90), isNull);
      expect(validate(maxReservations: 1), isNull);
      expect(validate(maxReservations: 50), isNull);
    });

    test('lane count outside 1–12 is rejected with the screen copy', () {
      expect(validate(laneCount: 0), 'Počet drah musí být 1–12.');
      expect(validate(laneCount: 13), 'Počet drah musí být 1–12.');
    });

    test('horizon outside 1–90 days is rejected with the screen copy', () {
      expect(validate(horizonDays: 0), 'Rezervace dopředu musí být 1–90 dní.');
      expect(validate(horizonDays: 91), 'Rezervace dopředu musí být 1–90 dní.');
    });

    test('max reservations outside 1–50 is rejected with the screen copy', () {
      expect(
        validate(maxReservations: 0),
        'Max. aktivních rezervací musí být 1–50.',
      );
      expect(
        validate(maxReservations: 51),
        'Max. aktivních rezervací musí být 1–50.',
      );
    });

    test('the first failing field (lanes, horizon, cap) wins', () {
      expect(
        validate(laneCount: 0, horizonDays: 0, maxReservations: 0),
        'Počet drah musí být 1–12.',
      );
      expect(
        validate(horizonDays: 0, maxReservations: 0),
        'Rezervace dopředu musí být 1–90 dní.',
      );
    });
  });

  group('validatePrepMinutes', () {
    test('0–240 inclusive passes', () {
      expect(validatePrepMinutes(0), isNull);
      expect(validatePrepMinutes(30), isNull);
      expect(validatePrepMinutes(240), isNull);
    });

    test('outside 0–240 is rejected with the dialog copy', () {
      expect(validatePrepMinutes(-1), 'Zadej 0–240 minut.');
      expect(validatePrepMinutes(241), 'Zadej 0–240 minut.');
    });
  });
}
