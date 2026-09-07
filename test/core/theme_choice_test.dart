import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/theme_choice.dart';

/// Contrast is its own axis here: five choices map onto (ThemeMode,
/// contrastLevel) independently of brightness.
void main() {
  test('system keeps normal contrast, following the OS brightness', () {
    final plan = themePlanFor(ThemeChoice.system);
    expect(plan.mode, ThemeMode.system);
    expect(plan.contrastLevel, 0.0);
  });

  test('light/dark force a brightness at normal contrast', () {
    final light = themePlanFor(ThemeChoice.light);
    expect(light.mode, ThemeMode.light);
    expect(light.contrastLevel, 0.0);

    final dark = themePlanFor(ThemeChoice.dark);
    expect(dark.mode, ThemeMode.dark);
    expect(dark.contrastLevel, 0.0);
  });

  test(
      'lightContrast/darkContrast force the same brightness at max contrast',
      () {
    final light = themePlanFor(ThemeChoice.lightContrast);
    expect(light.mode, ThemeMode.light);
    expect(light.contrastLevel, 1.0);

    final dark = themePlanFor(ThemeChoice.darkContrast);
    expect(dark.mode, ThemeMode.dark);
    expect(dark.contrastLevel, 1.0);
  });

  test('parse: round-trips through name, unknown/null falls back to system',
      () {
    for (final c in ThemeChoice.values) {
      expect(parseThemeChoice(c.name), c);
    }
    expect(parseThemeChoice(null), ThemeChoice.system);
    expect(parseThemeChoice('neon'), ThemeChoice.system);
  });
}
