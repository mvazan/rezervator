import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/text_size.dart';

void main() {
  test('steps mirror the Android system steps (100 / 115 / 130%)', () {
    expect(textSizeFactor(TextSizeChoice.normal), 1.0);
    expect(textSizeFactor(TextSizeChoice.large), 1.15);
    expect(textSizeFactor(TextSizeChoice.largest), 1.3);
  });

  test('parse: round-trips through name, unknown/null falls back to normal',
      () {
    for (final c in TextSizeChoice.values) {
      expect(parseTextSizeChoice(c.name), c);
    }
    expect(parseTextSizeChoice(null), TextSizeChoice.normal);
    expect(parseTextSizeChoice('mega'), TextSizeChoice.normal);
  });

  group('AppTextScaler', () {
    test('normal choice leaves the system scale alone', () {
      final s = AppTextScaler(TextScaler.linear(1.3), TextSizeChoice.normal);
      expect(s.scale(16), closeTo(20.8, 0.01));
    });

    test('the choice multiplies onto the system scale', () {
      expect(
          AppTextScaler(TextScaler.noScaling, TextSizeChoice.large).scale(16),
          closeTo(18.4, 0.01));
      expect(
          AppTextScaler(TextScaler.noScaling, TextSizeChoice.largest)
              .scale(16),
          closeTo(20.8, 0.01));
      // System 130% + "largest" choice = 169%.
      expect(
          AppTextScaler(TextScaler.linear(1.3), TextSizeChoice.largest)
              .scale(16),
          closeTo(27.04, 0.01));
    });

    test('never more than 200% of the design size (WCAG 1.4.4)', () {
      // System already at Android 14's own maximum (200%) — the choice must
      // not push past it.
      final s = AppTextScaler(TextScaler.linear(2.0), TextSizeChoice.largest);
      expect(s.scale(16), 32.0);
      expect(s.scale(20), 40.0);
    });

    test('zero size stays zero', () {
      expect(
          AppTextScaler(TextScaler.noScaling, TextSizeChoice.largest)
              .scale(0),
          0.0);
    });
  });
}
