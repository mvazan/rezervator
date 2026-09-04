import 'package:flutter/material.dart';

import '../../../domain/palette.dart';

/// Reusable club/rental color picker: a grid of the 12 [ClubColors] swatches
/// (rendered with each color's dark background, since that's the more
/// saturated/legible variant for a small swatch) plus a leading "none"
/// option.
///
/// The selected swatch is marked TWICE over: a check mark inside it, drawn
/// in that color's own foreground so it reads on every swatch, and a ring
/// around it separated by a gap. A single ring in the theme's primary was
/// invisible on the blue-ish swatches (and it ate into the color, because a
/// border is painted inside the box).
///
/// [noneValue] is the index reported for the "none" option and used to
/// detect it as selected (e.g. -1 "žádná" for a club, -2 "výchozí" for a
/// rental). [noneLabel] is its caption.
class ColorPickerGrid extends StatelessWidget {
  const ColorPickerGrid({
    super.key,
    required this.selected,
    required this.onChanged,
    this.noneValue = -1,
    this.noneLabel = 'Žádná',
  });

  final int selected;
  final ValueChanged<int> onChanged;
  final int noneValue;
  final String noneLabel;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _Swatch(
          selected: selected == noneValue,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          onColor: Theme.of(context).colorScheme.onSurfaceVariant,
          tooltip: noneLabel,
          onTap: () => onChanged(noneValue),
          child: const Icon(Icons.block, size: 18),
        ),
        for (var i = 0; i < ClubColors.count; i++)
          _Swatch(
            selected: selected == i,
            color: ClubColors.of(i, Brightness.dark)!.$1,
            onColor: ClubColors.of(i, Brightness.dark)!.$2,
            tooltip: ClubColors.names[i],
            onTap: () => onChanged(i),
          ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.selected,
    required this.color,
    required this.onColor,
    required this.tooltip,
    required this.onTap,
    this.child,
  });

  final bool selected;
  final Color color;

  /// The color's own foreground — what the check mark is drawn in, so it
  /// stays legible on a dark navy swatch as well as on a pale grey one.
  final Color onColor;
  final String tooltip;
  final VoidCallback onTap;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          // 44 is the comfortable tap target; the ring sits on its edge and
          // the padding keeps it clear of the color itself.
          width: 44,
          height: 44,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? scheme.onSurface : Colors.transparent,
              width: 2,
            ),
          ),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              // Hairline, so a pale swatch keeps an edge against the card.
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: selected
                ? Icon(Icons.check, size: 20, color: onColor)
                : child,
          ),
        ),
      ),
    );
  }
}
