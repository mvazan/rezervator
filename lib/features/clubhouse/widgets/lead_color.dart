import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../../../domain/palette.dart';

/// The colour a lead label („+22“, „-3“) is printed in: its side's — the
/// home side's for „+“, the guests' for „-“ — as text that stays legible on
/// the card (see [legibleSideText]); null for „=“ or no lead. [homeColor] and
/// [awayColor] default to green and red.
Color? leadColor(
  BuildContext context,
  String lead, {
  Color? homeColor,
  Color? awayColor,
}) {
  final home = lead.startsWith('+');
  if (!home && !lead.startsWith('-')) return null;
  final theme = Theme.of(context);
  return legibleSideText(
    home ? (homeColor ?? homeSideColor) : (awayColor ?? awaySideColor),
    theme.brightness,
    highContrast: (theme.extension<ContrastLevel>()?.value ?? 0) > 0,
  );
}
