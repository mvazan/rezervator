/// One module of the kiosk's header (0081): a small title over its value.
/// Every module has the same height — a title line, then a value box
/// [kioskHeaderValueHeight] tall (scaled with the text) — so the bar,
/// which centres its children, lines all titles up and all values up.
library;

import 'package:flutter/material.dart';

/// The value box's height at text scale 1: room for the clock's 28 px.
const kioskHeaderValueHeight = 34.0;

/// The space between two modules.
const kioskHeaderGap = 32.0;

/// The share of the screen's width a module with a short value (weather,
/// name day, duty) may take: the centre, the notices and „Rezervace
/// tréninku“ keep their room on a narrow kiosk with large text.
const kioskHeaderModuleShare = 0.2;

/// A module's title: small, quiet, one line.
TextStyle kioskHeaderTitleStyle(ColorScheme scheme) => TextStyle(
  fontSize: 13,
  height: 1.3,
  fontWeight: FontWeight.w600,
  color: scheme.onSurfaceVariant,
);

/// A name as a module's value (name day, duty).
TextStyle kioskHeaderNameStyle(ColorScheme scheme) => TextStyle(
  fontSize: 22,
  fontWeight: FontWeight.w700,
  color: scheme.onSurface,
);

class KioskHeaderModuleFrame extends StatelessWidget {
  const KioskHeaderModuleFrame({
    super.key,
    required this.title,
    required this.child,
    this.onTap,
    this.maxWidth,
  });

  final String title;

  /// The value, laid left in its box.
  final Widget child;

  /// A tap anywhere on the module.
  final VoidCallback? onTap;

  /// Null: as wide as the value (or, under an Expanded, the room given).
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget module = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: kioskHeaderTitleStyle(scheme),
        ),
        SizedBox(
          height: MediaQuery.textScalerOf(
            context,
          ).scale(kioskHeaderValueHeight),
          // widthFactor 1: as wide as the value, not the room it may take.
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: 1,
            child: child,
          ),
        ),
      ],
    );
    if (onTap != null) {
      module = InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: module,
      );
    }
    final cap = maxWidth;
    return cap == null
        ? module
        : ConstrainedBox(
            constraints: BoxConstraints(maxWidth: cap),
            child: module,
          );
  }
}
