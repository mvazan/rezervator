import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/contrast.dart';
import 'package:rezervator/core/theme.dart';

/// WCAG 2.1 AA: normal text 4.5:1, shapes and UI elements 3:1.
const _textAA = 4.5;
const _shapeAA = 3.0;

/// WCAG 2.1 AAA: normal text 7:1, shapes 4.5:1 — the bar for the two
/// CONTRAST variants (see `_barsFor` below). Real high contrast clears this
/// with room to spare (worst measured: 8.96 light, 9.34 dark); a leaked
/// "Noční liga" ramp does not, because every ramp pair hard-codes both
/// sides so its ratio never moves with `contrastLevel` — measured at 4.70
/// (light) / 6.67 (dark) when the ramp is wrongly re-applied on top of
/// `fromSeed(contrastLevel: 1)`. AA (4.5/3.0) does NOT separate the two: the
/// leak clears AA in both brightnesses, which is exactly why AA alone
/// cannot catch the regression this file guards against — see the `if
/// (contrastLevel == 0)` guard at theme.dart:75.
const _textAAA = 7.0;
const _shapeAAA = 4.5;

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

/// The bar a variant is held to: AAA for the two CONTRAST choices (the only
/// bar that provably depends on `contrastLevel` actually holding — see
/// `_textAAA` above), AA for `light`/`dark`/`system`.
(double text, double shape) _barsFor(double contrastLevel) =>
    contrastLevel == 1 ? (_textAAA, _shapeAAA) : (_textAA, _shapeAA);

void _expectText(double ratio, String what, String variant, double bar) {
  expect(ratio, greaterThanOrEqualTo(bar),
      reason: '$variant: $what has contrast ${ratio.toStringAsFixed(2)}:1, '
          'wants $bar:1');
}

void _expectShape(double ratio, String what, String variant, double bar) {
  expect(ratio, greaterThanOrEqualTo(bar),
      reason: '$variant: $what has contrast ${ratio.toStringAsFixed(2)}:1, '
          'wants $bar:1 for shapes');
}

void main() {
  for (final (variant, brightness, contrastLevel) in _variants) {
    final theme = buildTheme(brightness, contrastLevel: contrastLevel);
    final scheme = theme.colorScheme;
    final page = theme.scaffoldBackgroundColor;
    final (textBar, shapeBar) = _barsFor(contrastLevel);

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
              'onSurface on $name', variant, textBar);
        }
      });

      test('text on primary and primaryContainer is legible', () {
        _expectText(contrastRatio(scheme.onPrimary, scheme.primary),
            'onPrimary on primary', variant, textBar);
        _expectText(
            contrastRatio(scheme.onPrimaryContainer, scheme.primaryContainer),
            'onPrimaryContainer on primaryContainer',
            variant,
            textBar);
      });

      test('text on secondary and secondaryContainer is legible', () {
        _expectText(contrastRatio(scheme.onSecondary, scheme.secondary),
            'onSecondary on secondary', variant, textBar);
        _expectText(
            contrastRatio(
                scheme.onSecondaryContainer, scheme.secondaryContainer),
            'onSecondaryContainer on secondaryContainer',
            variant,
            textBar);
      });

      test('text on tertiary and tertiaryContainer is legible', () {
        _expectText(contrastRatio(scheme.onTertiary, scheme.tertiary),
            'onTertiary on tertiary', variant, textBar);
        _expectText(
            contrastRatio(
                scheme.onTertiaryContainer, scheme.tertiaryContainer),
            'onTertiaryContainer on tertiaryContainer',
            variant,
            textBar);
      });

      test('text on error and errorContainer is legible', () {
        _expectText(contrastRatio(scheme.onError, scheme.error),
            'onError on error', variant, textBar);
        _expectText(
            contrastRatio(scheme.onErrorContainer, scheme.errorContainer),
            'onErrorContainer on errorContainer',
            variant,
            textBar);
      });

      test('outline is visible against the page background', () {
        _expectShape(contrastRatio(scheme.outline, scheme.surface),
            'outline on surface', variant, shapeBar);
      });

      // Rendered surfaces, not just raw scheme roles: a role can measure
      // fine in isolation and still render illegibly if the widget that
      // actually paints it diverges (translucent fills below) or if the
      // role the app renders isn't the one being measured (the card's
      // border used outlineVariant — a role dividers/chips use for
      // low-emphasis lines — while this test checked outline, a pair the
      // app barely renders; see core/theme.dart's cardTheme).
      test('the card is visible against the page background', () {
        final side = (theme.cardTheme.shape! as RoundedRectangleBorder).side;
        final visible = [
          contrastRatio(theme.cardTheme.color!, page),
          if (side.style != BorderStyle.none)
            contrastRatio(side.color, page),
        ].reduce((a, b) => a > b ? a : b);
        expect(visible, greaterThanOrEqualTo(shapeBar),
            reason: '$variant: card blends into the page — fill and border '
                'both under $shapeBar:1 (best ${visible.toStringAsFixed(2)}:1)');
      });

      test('text on the card and in an input field is legible', () {
        _expectText(contrastRatio(scheme.onSurface, theme.cardTheme.color!),
            'text on card', variant, textBar);
        _expectText(
            contrastRatio(
                scheme.onSurface, theme.inputDecorationTheme.fillColor!),
            'text in input field',
            variant,
            textBar);
      });

      // The three translucent-fill sites the schedule day header/column
      // render (day_header.dart's availability pill, schedule_day_column
      // .dart's match/rental band fallback tints): each is a container role
      // washed toward the page with its own alpha, paired with the
      // container's `on*` colour. `containerTint` is the one place that
      // decides whether to keep the wash (contrastLevel 0) or drop it in
      // favour of the full-strength container (contrastLevel 1, where
      // Material already tuned the `on*` colour against the FULL
      // container — see core/theme.dart). Composited against the real
      // page background, exactly as Flutter paints it.
      test('the availability pill is legible', () {
        final (fill, on) = containerTint(
          container: scheme.primaryContainer,
          onContainer: scheme.onPrimaryContainer,
          alpha: 0.5,
          contrastLevel: contrastLevel,
        );
        _expectText(contrastRatio(on, composite(fill, page)),
            'availability pill text', variant, textBar);
      });

      test('the match band fallback tint is legible', () {
        final (fill, on) = containerTint(
          container: scheme.errorContainer,
          onContainer: scheme.onErrorContainer,
          alpha: 0.6,
          contrastLevel: contrastLevel,
        );
        _expectText(contrastRatio(on, composite(fill, page)),
            'match band fallback text', variant, textBar);
      });

      test('the rental band fallback tint is legible', () {
        final (fill, on) = containerTint(
          container: scheme.tertiaryContainer,
          onContainer: scheme.onTertiaryContainer,
          alpha: 0.5,
          contrastLevel: contrastLevel,
        );
        _expectText(contrastRatio(on, composite(fill, page)),
            'rental band fallback text', variant, textBar);
      });
    });
  }
}
