/// Numeric bounds the admin and registration forms enforce, and the
/// validators that turn a violation into the Czech message the screen shows.
/// Pure Dart — no Flutter imports.
library;

/// Inclusive `(min, max)` ranges and single caps. Forms read their hints
/// from here; the validators below reject anything outside.
abstract final class Limits {
  static const laneCount = (min: 1, max: 12);
  static const horizonDays = (min: 1, max: 90);
  static const maxActiveReservations = (min: 1, max: 50);
  static const prepMinutes = (min: 0, max: 240);

  /// Longest closure range one "Přidat výjimku" save may span (≈ 3 months).
  static const closureSpanDays = 92;

  /// Board nick cap (mirrors the `profiles.nick` length check).
  static const nickLength = 14;
}

bool _within(int value, ({int min, int max}) range) =>
    value >= range.min && value <= range.max;

/// "1–12" — the od–do wording every range message uses.
String _span(({int min, int max}) range) => '${range.min}–${range.max}';

/// Czech error copy (moved verbatim from schedule_screen._validate) or null.
String? validateScheduleSettings({
  required int laneCount,
  required int horizonDays,
  required int maxReservations,
}) {
  if (!_within(laneCount, Limits.laneCount)) {
    return 'Počet drah musí být ${_span(Limits.laneCount)}.';
  }
  if (!_within(horizonDays, Limits.horizonDays)) {
    return 'Rezervace dopředu musí být ${_span(Limits.horizonDays)} dní.';
  }
  if (!_within(maxReservations, Limits.maxActiveReservations)) {
    return 'Max. aktivních rezervací musí být '
        '${_span(Limits.maxActiveReservations)}.';
  }
  return null;
}

/// 'Zadej 0–240 minut.' or null.
String? validatePrepMinutes(int minutes) => _within(minutes, Limits.prepMinutes)
    ? null
    : 'Zadej ${_span(Limits.prepMinutes)} minut.';
