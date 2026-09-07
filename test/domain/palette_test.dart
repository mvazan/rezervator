import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/palette.dart';

void main() {
  group('ClubColors', () {
    test('has 9 colors and 9 names', () {
      expect(ClubColors.count, 9);
      expect(ClubColors.names, hasLength(9));
    });

    test('no two entries look alike: every pair is at least ΔE2000 10 apart',
        () {
      // The three that were closer than this (Oranžová, Limetka, Indigo) are
      // what migration 0031 dropped; a new entry has to clear the same bar.
      for (var i = 0; i < ClubColors.count; i++) {
        for (var j = i + 1; j < ClubColors.count; j++) {
          final a = ClubColors.of(i, Brightness.dark)!.$1;
          final b = ClubColors.of(j, Brightness.dark)!.$1;
          expect(deltaE2000(a, b), greaterThanOrEqualTo(10),
              reason: '${ClubColors.names[i]} ~ ${ClubColors.names[j]}');
        }
      }
    });

    test('of(0, dark) returns the first entry bg/fg', () {
      final (bg, fg) = ClubColors.of(0, Brightness.dark)!;
      expect(bg, const Color(0xFF1E3A8A));
      expect(fg, const Color(0xFFBFDBFE));
    });

    test('of(0, light) returns the first entry light bg/fg', () {
      final (bg, fg) = ClubColors.of(0, Brightness.light)!;
      expect(bg, const Color(0xFFDBEAFE));
      expect(fg, const Color(0xFF1E3A8A));
    });

    test('of(8, ...) is in range for both brightnesses', () {
      expect(ClubColors.of(8, Brightness.dark), isNotNull);
      expect(ClubColors.of(8, Brightness.light), isNotNull);
    });

    test('of returns null for out-of-range indices in both brightnesses', () {
      for (final b in Brightness.values) {
        expect(ClubColors.of(-1, b), isNull); // "no club"
        expect(ClubColors.of(-2, b), isNull); // rental default
        expect(ClubColors.of(12, b), isNull); // past end
      }
    });
  });

  group('clubTint', () {
    const fallbackBg = Color(0xFF101010);
    const fallbackFg = Color(0xFFEFEFEF);

    test('in-range index resolves to the palette entry', () {
      expect(
        clubTint(0, Brightness.dark,
            fallbackBg: fallbackBg, fallbackFg: fallbackFg),
        ClubColors.of(0, Brightness.dark),
      );
      expect(
        clubTint(8, Brightness.light,
            fallbackBg: fallbackBg, fallbackFg: fallbackFg),
        ClubColors.of(8, Brightness.light),
      );
    });

    test("out-of-range index yields the caller's fallback pair", () {
      for (final b in Brightness.values) {
        for (final index in [-1, -2, 9]) {
          expect(
            clubTint(index, b, fallbackBg: fallbackBg, fallbackFg: fallbackFg),
            (fallbackBg, fallbackFg),
            reason: 'index $index, $b',
          );
        }
      }
    });

    test('a hand-picked colour tints instead of falling back', () {
      final value = packCustomColor(const Color(0xFF3366CC));
      for (final b in Brightness.values) {
        expect(
          clubTint(value, b, fallbackBg: fallbackBg, fallbackFg: fallbackFg),
          customTint(value, b),
          reason: '$b',
        );
      }
    });
  });

  group('hand-picked colours', () {
    test('pack keeps the rgb and drops the alpha, unpack gives it back', () {
      const picked = Color(0x803366CC);
      final value = packCustomColor(picked);
      expect(value, 0x1000000 | 0x3366CC);
      expect(unpackCustomColor(value), const Color(0xFF3366CC));
    });

    test('only the packed range counts as hand-picked', () {
      expect(isCustomColor(packCustomColor(const Color(0xFF000000))), isTrue);
      expect(isCustomColor(packCustomColor(const Color(0xFFFFFFFF))), isTrue);
      for (final v in [-2, -1, 0, 11, 12, 0xFFFFFF, 0x2000000]) {
        expect(isCustomColor(v), isFalse, reason: '$v');
      }
    });

    test('the derived pair reads like a palette entry: dark bg, pale text '
        'in the dark theme and the other way round in the light one', () {
      for (final picked in [
        const Color(0xFF3366CC),
        const Color(0xFFFF0000),
        const Color(0xFF00FF88),
        const Color(0xFF888888),
      ]) {
        final value = packCustomColor(picked);
        final (darkBg, darkFg) = customTint(value, Brightness.dark);
        final (lightBg, lightFg) = customTint(value, Brightness.light);
        expect(darkBg.computeLuminance(), lessThan(darkFg.computeLuminance()),
            reason: '$picked dark');
        expect(lightFg.computeLuminance(), lessThan(lightBg.computeLuminance()),
            reason: '$picked light');
        // The palette's own entries clear 4.5:1; a derived pair must too, or
        // a hand-picked colour would be the one unreadable cell on the board.
        for (final (bg, fg) in [(darkBg, darkFg), (lightBg, lightFg)]) {
          final l1 = bg.computeLuminance(), l2 = fg.computeLuminance();
          final ratio = (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05);
          expect(ratio, greaterThanOrEqualTo(4.5), reason: '$picked $bg/$fg');
        }
      }
    });

    test('a washed-out pick still comes out as a colour, not four greys', () {
      final value = packCustomColor(const Color(0xFFF2F0F5));
      final (bg, _) = customTint(value, Brightness.dark);
      expect(HSLColor.fromColor(bg).saturation, greaterThanOrEqualTo(0.25));
    });
  });
}

/// CIEDE2000 between two colours — the measure used to decide which palette
/// entries were duplicates (migration 0031). Test-only: the app never needs
/// to compare two colours at runtime, it only renders them.
double deltaE2000(Color x, Color y) {
  final (l1, a1, b1) = _lab(x);
  final (l2, a2, b2) = _lab(y);
  final c1 = sqrt(a1 * a1 + b1 * b1), c2 = sqrt(a2 * a2 + b2 * b2);
  final cb = (c1 + c2) / 2;
  final g = 0.5 * (1 - sqrt(pow(cb, 7) / (pow(cb, 7) + pow(25, 7))));
  final a1p = (1 + g) * a1, a2p = (1 + g) * a2;
  final c1p = sqrt(a1p * a1p + b1 * b1), c2p = sqrt(a2p * a2p + b2 * b2);
  double hue(double a, double b) {
    if (a == 0 && b == 0) return 0;
    final h = atan2(b, a) * 180 / pi;
    return h < 0 ? h + 360 : h;
  }

  final h1p = hue(a1p, b1), h2p = hue(a2p, b2);
  final dLp = l2 - l1, dCp = c2p - c1p;
  double dhp;
  if (c1p * c2p == 0) {
    dhp = 0;
  } else if ((h2p - h1p).abs() <= 180) {
    dhp = h2p - h1p;
  } else {
    dhp = h2p > h1p ? h2p - h1p - 360 : h2p - h1p + 360;
  }
  final dHp = 2 * sqrt(c1p * c2p) * sin(dhp * pi / 360);
  final lbp = (l1 + l2) / 2, cbp = (c1p + c2p) / 2;
  double hbp;
  if (c1p * c2p == 0) {
    hbp = h1p + h2p;
  } else if ((h1p - h2p).abs() <= 180) {
    hbp = (h1p + h2p) / 2;
  } else {
    hbp = h1p + h2p < 360 ? (h1p + h2p + 360) / 2 : (h1p + h2p - 360) / 2;
  }
  double cosd(double deg) => cos(deg * pi / 180);
  final tt = 1 -
      0.17 * cosd(hbp - 30) +
      0.24 * cosd(2 * hbp) +
      0.32 * cosd(3 * hbp + 6) -
      0.20 * cosd(4 * hbp - 63);
  final dTh = 30 * exp(-pow((hbp - 275) / 25, 2).toDouble());
  final rc = 2 * sqrt(pow(cbp, 7) / (pow(cbp, 7) + pow(25, 7)));
  final sl = 1 + (0.015 * pow(lbp - 50, 2)) / sqrt(20 + pow(lbp - 50, 2));
  final sc = 1 + 0.045 * cbp, sh = 1 + 0.015 * cbp * tt;
  final rt = -sin(2 * dTh * pi / 180) * rc;
  return sqrt(pow(dLp / sl, 2) +
      pow(dCp / sc, 2) +
      pow(dHp / sh, 2) +
      rt * (dCp / sc) * (dHp / sh));
}

(double, double, double) _lab(Color c) {
  double lin(double v) =>
      v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();
  final r = lin(c.r), g = lin(c.g), b = lin(c.b);
  final x = (r * 0.4124564 + g * 0.3575761 + b * 0.1804375) / 0.95047;
  final y = r * 0.2126729 + g * 0.7151522 + b * 0.0721750;
  final z = (r * 0.0193339 + g * 0.1191920 + b * 0.9503041) / 1.08883;
  double f(double t) =>
      t > 0.008856 ? pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;
  final fx = f(x), fy = f(y), fz = f(z);
  return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz));
}
