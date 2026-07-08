import 'package:flutter/material.dart';

/// Club color palette (spec §2). Index 0–11 = a club color; anything else
/// (e.g. -1 "no club", -2 rental default) → the neutral fallback.
class ClubColors {
  const ClubColors._();
  // Each entry: [darkBg, darkFg, lightBg, lightFg] as 0xFF ints.
  static const _p = <List<int>>[
    [0xFF1E3A8A, 0xFFBFDBFE, 0xFFDBEAFE, 0xFF1E3A8A], // Modrá
    [0xFF14532D, 0xFFBBF7D0, 0xFFDCFCE7, 0xFF166534], // Zelená
    [0xFF7F1D1D, 0xFFFECACA, 0xFFFEE2E2, 0xFF991B1B], // Červená
    [0xFF7C2D12, 0xFFFED7AA, 0xFFFFEDD5, 0xFF9A3412], // Oranžová
    [0xFF4C1D95, 0xFFDDD6FE, 0xFFEDE9FE, 0xFF5B21B6], // Fialová
    [0xFF134E4A, 0xFF99F6E4, 0xFFCCFBF1, 0xFF115E59], // Tyrkys
    [0xFF831843, 0xFFFBCFE8, 0xFFFCE7F3, 0xFF9D174D], // Růžová
    [0xFF713F12, 0xFFFDE68A, 0xFFFEF9C3, 0xFF854D0E], // Žlutá
    [0xFF365314, 0xFFD9F99D, 0xFFECFCCB, 0xFF3F6212], // Limetka
    [0xFF312E81, 0xFFC7D2FE, 0xFFE0E7FF, 0xFF3730A3], // Indigo
    [0xFF44403C, 0xFFE7E5E4, 0xFFE7E5E4, 0xFF44403C], // Hnědá
    [0xFF334155, 0xFFCBD5E1, 0xFFE2E8F0, 0xFF334155], // Šedá
  ];
  static const names = [
    'Modrá',
    'Zelená',
    'Červená',
    'Oranžová',
    'Fialová',
    'Tyrkys',
    'Růžová',
    'Žlutá',
    'Limetka',
    'Indigo',
    'Hnědá',
    'Šedá',
  ];
  static int get count => _p.length;

  /// Background+foreground for [index] at [brightness]; null when [index] is
  /// out of 0–11 (caller uses its own neutral tint).
  static (Color bg, Color fg)? of(int index, Brightness b) {
    if (index < 0 || index >= _p.length) return null;
    final e = _p[index];
    return b == Brightness.dark
        ? (Color(e[0]), Color(e[1]))
        : (Color(e[2]), Color(e[3]));
  }
}
