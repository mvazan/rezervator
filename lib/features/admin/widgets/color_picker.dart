import 'package:flutter/material.dart';

import '../../../domain/palette.dart';

/// Reusable club/rental color picker: a grid of the 12 [ClubColors] swatches
/// (rendered with each color's dark background, since that's the more
/// saturated/legible variant for a small swatch) plus a leading "none"
/// option. The selected swatch gets a ring around it.
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
          tooltip: noneLabel,
          onTap: () => onChanged(noneValue),
          child: const Icon(Icons.block, size: 18),
        ),
        for (var i = 0; i < ClubColors.count; i++)
          _Swatch(
            selected: selected == i,
            color: ClubColors.of(i, Brightness.dark)!.$1,
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
    required this.tooltip,
    required this.onTap,
    this.child,
  });

  final bool selected;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final ringColor = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? ringColor : Colors.transparent,
              width: 3,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
