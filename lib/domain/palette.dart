import 'package:flutter/material.dart';

/// A hand-picked colour is stored in the same column as a palette index,
/// packed above the palette's range as 0x1000000 | rgb — see migration 0030.
/// Below that, values keep their old meaning: 0–11 a palette entry, -1 "no
/// club" / "none", -2 the rental default.
const customColorFlag = 0x1000000;

/// True when [value] carries a hand-picked colour rather than a palette
/// index or one of the negative "none" markers.
bool isCustomColor(int value) =>
    value >= customColorFlag && value <= customColorFlag | 0xFFFFFF;

/// The column value for a hand-picked [color] (its alpha is dropped — the
/// four rendered variants are derived, so only the hue and saturation of the
/// chosen colour survive anyway).
int packCustomColor(Color color) =>
    customColorFlag | (color.toARGB32() & 0xFFFFFF);

/// The colour the user actually picked, for showing it back in the picker.
Color unpackCustomColor(int value) => Color(0xFF000000 | (value & 0xFFFFFF));

/// Background + foreground for a hand-picked colour, shaded the way the
/// palette's own entries are: a deep background with pale text in the dark
/// theme, a very pale background with deep text in the light one. Deriving
/// both ends from the chosen hue — rather than painting the raw colour —
/// is what keeps a hand-picked colour as readable as a preset one, whatever
/// the user picks.
(Color bg, Color fg) customTint(int value, Brightness brightness) {
  final hsl = HSLColor.fromColor(unpackCustomColor(value));
  // A washed-out pick would derive four near-greys that no longer read as a
  // colour at all; a fully saturated one turns garish once darkened.
  final s = hsl.saturation.clamp(0.25, 0.85);
  HSLColor at(double lightness) =>
      HSLColor.fromAHSL(1, hsl.hue, s, lightness);
  return brightness == Brightness.dark
      ? (at(0.24).toColor(), at(0.86).toColor())
      : (at(0.92).toColor(), at(0.27).toColor());
}

/// Club color palette (spec §2). Index 0–8 = a club color; anything else
/// (e.g. -1 "no club", -2 rental default) → the neutral fallback.
///
/// Nine entries, not the original twelve: Oranžová, Limetka and Indigo each
/// measured under ΔE2000 10 from a neighbour (7.8 from Červená, 9.5 from
/// Zelená, 5.6 from Modrá), which side by side in the picker read as the same
/// circle twice. Migration 0031 dropped them and kept every affected row on
/// its exact colour as a hand-picked one. What survives is at least ΔE 10.3
/// apart — keep it that way when adding an entry.
class ClubColors {
  const ClubColors._();
  // Each entry: [darkBg, darkFg, lightBg, lightFg] as 0xFF ints.
  static const _p = <List<int>>[
    [0xFF1E3A8A, 0xFFBFDBFE, 0xFFDBEAFE, 0xFF1E3A8A], // Modrá
    [0xFF14532D, 0xFFBBF7D0, 0xFFDCFCE7, 0xFF166534], // Zelená
    [0xFF7F1D1D, 0xFFFECACA, 0xFFFEE2E2, 0xFF991B1B], // Červená
    [0xFF4C1D95, 0xFFDDD6FE, 0xFFEDE9FE, 0xFF5B21B6], // Fialová
    [0xFF134E4A, 0xFF99F6E4, 0xFFCCFBF1, 0xFF115E59], // Tyrkys
    [0xFF831843, 0xFFFBCFE8, 0xFFFCE7F3, 0xFF9D174D], // Růžová
    [0xFF713F12, 0xFFFDE68A, 0xFFFEF9C3, 0xFF854D0E], // Žlutá
    [0xFF44403C, 0xFFE7E5E4, 0xFFE7E5E4, 0xFF44403C], // Hnědá
    [0xFF334155, 0xFFCBD5E1, 0xFFE2E8F0, 0xFF334155], // Šedá
  ];
  static const names = [
    'Modrá',
    'Zelená',
    'Červená',
    'Fialová',
    'Tyrkys',
    'Růžová',
    'Žlutá',
    'Hnědá',
    'Šedá',
  ];
  static int get count => _p.length;

  /// Background+foreground for [index] at [brightness]: a palette entry for
  /// 0–11, the derived shades for a hand-picked colour, null otherwise (the
  /// caller uses its own neutral tint).
  static (Color bg, Color fg)? of(int index, Brightness b) {
    if (isCustomColor(index)) return customTint(index, b);
    if (index < 0 || index >= _p.length) return null;
    final e = _p[index];
    return b == Brightness.dark
        ? (Color(e[0]), Color(e[1]))
        : (Color(e[2]), Color(e[3]));
  }
}

/// Background + foreground for a palette index, or the caller's neutral
/// fallback when the index is out of 0–11 (−1 "no club", −2 rental default…).
(Color bg, Color fg) clubTint(
  int index,
  Brightness brightness, {
  required Color fallbackBg,
  required Color fallbackFg,
}) =>
    ClubColors.of(index, brightness) ?? (fallbackBg, fallbackFg);
