import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/contrast.dart';
import 'package:rezervator/core/theme.dart';

/// WCAG 2.1 AA: normal text 4.5:1, shapes and UI elements 3:1.
const _textAA = 4.5;
const _shapeAA = 3.0;

/// Every renderable brightness × contrast combination a person can pick in
/// Settings (see core/theme_choice.dart). All five [ThemeChoice] values
/// collapse onto these four: `system` follows the OS at contrast 0, and the
/// plain/contrast pairs share brightness × contrastLevel with `light`/`dark`.
const _variants = <(String, Brightness, double)>[
  ('Light', Brightness.light, 0.0),
  ('Dark', Brightness.dark, 0.0),
  ('Light — high contrast', Brightness.light, 1.0),
  ('Dark — high contrast', Brightness.dark, 1.0),
];

void _expectText(double ratio, String what, String variant) {
  expect(ratio, greaterThanOrEqualTo(_textAA),
      reason: '$variant: $what has contrast ${ratio.toStringAsFixed(2)}:1, '
          'AA wants $_textAA:1');
}

void main() {
  for (final (variant, brightness, contrastLevel) in _variants) {
    final scheme =
        buildTheme(brightness, contrastLevel: contrastLevel).colorScheme;

    group(variant, () {
      test('text on surface and every surfaceContainer* is legible', () {
        for (final (name, fill) in <(String, Color)>[
          ('surface', scheme.surface),
          ('surfaceContainerLowest', scheme.surfaceContainerLowest),
          ('surfaceContainerLow', scheme.surfaceContainerLow),
          ('surfaceContainer', scheme.surfaceContainer),
          ('surfaceContainerHigh', scheme.surfaceContainerHigh),
          ('surfaceContainerHighest', scheme.surfaceContainerHighest),
        ]) {
          _expectText(contrastRatio(scheme.onSurface, fill),
              'onSurface on $name', variant);
        }
      });

      test('text on primary and primaryContainer is legible', () {
        _expectText(contrastRatio(scheme.onPrimary, scheme.primary),
            'onPrimary on primary', variant);
        _expectText(
            contrastRatio(scheme.onPrimaryContainer, scheme.primaryContainer),
            'onPrimaryContainer on primaryContainer',
            variant);
      });

      test('text on secondary and secondaryContainer is legible', () {
        _expectText(contrastRatio(scheme.onSecondary, scheme.secondary),
            'onSecondary on secondary', variant);
        _expectText(
            contrastRatio(
                scheme.onSecondaryContainer, scheme.secondaryContainer),
            'onSecondaryContainer on secondaryContainer',
            variant);
      });

      test('text on tertiary and tertiaryContainer is legible', () {
        _expectText(contrastRatio(scheme.onTertiary, scheme.tertiary),
            'onTertiary on tertiary', variant);
        _expectText(
            contrastRatio(
                scheme.onTertiaryContainer, scheme.tertiaryContainer),
            'onTertiaryContainer on tertiaryContainer',
            variant);
      });

      test('text on error and errorContainer is legible', () {
        _expectText(contrastRatio(scheme.onError, scheme.error),
            'onError on error', variant);
        _expectText(
            contrastRatio(scheme.onErrorContainer, scheme.errorContainer),
            'onErrorContainer on errorContainer',
            variant);
      });

      test('outline is visible against the page background', () {
        final ratio = contrastRatio(scheme.outline, scheme.surface);
        expect(ratio, greaterThanOrEqualTo(_shapeAA),
            reason: '$variant: outline on surface has contrast '
                '${ratio.toStringAsFixed(2)}:1, AA wants $_shapeAA:1 for '
                'shapes');
      });
    });
  }
}
