import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/contrast.dart';
import 'package:rezervator/core/theme.dart';
import 'package:rezervator/domain/palette.dart';

/// What the kiosk picker's colours are held to, measured rather than
/// eyeballed. The picker paints a player's CLUB colour behind their name, so
/// "readable" here has to survive every palette entry, both kiosk
/// brightnesses, and any colour an admin may hand-pick for a club.
///
/// WCAG 2.1 AA:
///  - 4.5:1 for normal text,
///  - 3:1 for LARGE text (≥18.66px bold — the name is 22px bold) and for
///    the boundary of a user-interface component (1.4.11), which is what a
///    tile's outline against the page has to clear for the target to be
///    visible at all.
const _textAA = 4.5;
const _largeTextAA = 3.0;
const _uiAA = 3.0;

void _expect(double ratio, double bar, String what) {
  expect(ratio, greaterThanOrEqualTo(bar),
      reason: '$what measures ${ratio.toStringAsFixed(2)}:1, wants $bar:1');
}

void main() {
  for (final brightness in [Brightness.dark, Brightness.light]) {
    final theme = buildTheme(brightness);
    final scheme = theme.colorScheme;
    final page = theme.scaffoldBackgroundColor;
    final variant = 'kiosk ${brightness.name}';

    group(variant, () {
      test('every club colour carries the name and outlines the tile', () {
        for (var i = 0; i < ClubColors.count; i++) {
          final (bg, fg) = ClubColors.of(i, brightness)!;
          final club = ClubColors.names[i];
          // The name: large text on the club fill.
          _expect(contrastRatio(fg, bg), _textAA, '$variant: $club name on fill');
          // The outline: the fill itself is nowhere near visible against the
          // page (asserted below), so the tile's own text colour draws its
          // edge.
          _expect(contrastRatio(fg, page), _uiAA, '$variant: $club outline on page');
        }
      });

      test('a club FILL alone would not delineate the tile — which is why '
          'there is an outline', () {
        // Not a bar to clear but the measurement the design rests on: if
        // some future palette entry ever did clear 3:1 against the page on
        // its own, the outline would be belt and braces rather than the
        // only thing making the target visible.
        final fills = [
          for (var i = 0; i < ClubColors.count; i++)
            contrastRatio(ClubColors.of(i, brightness)!.$1, page),
        ];
        expect(fills.reduce((a, b) => a > b ? a : b), lessThan(_uiAA),
            reason: '$variant: club fills measure '
                '${fills.map((r) => r.toStringAsFixed(2)).join(', ')} against '
                'the page');
      });

      test('a hand-picked club colour stays readable at every hue', () {
        var worstOnFill = 21.0;
        var worstOutline = 21.0;
        for (var hue = 0; hue < 360; hue++) {
          for (final saturation in [0.1, 0.3, 0.6, 0.9, 1.0]) {
            for (final lightness in [0.2, 0.5, 0.8]) {
              final packed = packCustomColor(
                  HSLColor.fromAHSL(1, hue.toDouble(), saturation, lightness)
                      .toColor());
              final (bg, fg) = customTint(packed, brightness);
              final onFill = contrastRatio(fg, bg);
              final outline = contrastRatio(fg, page);
              if (onFill < worstOnFill) worstOnFill = onFill;
              if (outline < worstOutline) worstOutline = outline;
            }
          }
        }
        // The name is large text (22px bold), so 3:1 — and this is exactly
        // why the tile carries no smaller second line (a club label, say):
        // at these ratios normal text would fail its 4.5:1 bar.
        _expect(worstOnFill, _largeTextAA, '$variant: worst hand-picked name on fill');
        _expect(worstOutline, _uiAA, '$variant: worst hand-picked outline on page');
      });

      test('a clubless player and the letter tiles read on the neutral '
          'surface', () {
        final fill = scheme.surfaceContainerHigh;
        _expect(contrastRatio(scheme.onSurface, fill), _textAA,
            '$variant: name/letter on the neutral tile');
        // The neutral fill is as invisible against the page as a club fill,
        // so these tiles are outlined too — with scheme.outline, which
        // clears the bar where the softer outlineVariant does not.
        expect(contrastRatio(fill, page), lessThan(_uiAA));
        _expect(contrastRatio(scheme.outline, page), _uiAA,
            '$variant: neutral tile outline on page');
        expect(contrastRatio(scheme.outlineVariant, page), lessThan(_uiAA),
            reason: '$variant: outlineVariant is the one that would NOT do');
      });
    });
  }
}
