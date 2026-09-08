import 'package:flutter/material.dart';

import '../../../domain/models.dart';
import 'home_header.dart';

/// The calendar's take on the home's top strip: [HomeHeader] with the week
/// navigation in its middle slot. The strip itself — title, padding, the
/// icons at the right edge — is the shared one, so it lines up with Můj
/// přehled's to the pixel.
class WeekHeader extends StatelessWidget {
  const WeekHeader({
    super.key,
    required this.monday,
    required this.weekOffset,
    required this.onGo,
    required this.trailing,
  });

  final Day monday;

  /// 0 = this week → no "dnes" button.
  final int weekOffset;

  /// Week navigation: -1 / +1 a week, 0 = today.
  final void Function(int delta) onGo;

  /// Action icons pinned to the right edge — in landscape the shell has no
  /// AppBar and parks its icons here (one shared top line).
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) => HomeHeader(
        trailing: trailing,
        middle: (stacked) => _weekNav(context, stacked),
      );

  // On one line the week selector sits centred between the title and the
  // icons; stacked it has the second line to itself, so the range can take
  // all the width between the two arrows.
  Widget _weekNav(BuildContext context, bool stacked) {
    final navPrev = IconButton(
      icon: const Icon(Icons.chevron_left),
      visualDensity: VisualDensity.compact,
      onPressed: () => onGo(-1),
    );
    final navNext = IconButton(
      icon: const Icon(Icons.chevron_right),
      visualDensity: VisualDensity.compact,
      onPressed: () => onGo(1),
    );
    final range = Text(
      rangeLabel(monday, monday.addDays(6)),
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleMedium,
    );
    final todayButton = weekOffset == 0
        ? null
        : TextButton(onPressed: () => onGo(0), child: const Text('dnes'));
    return stacked
        ? Row(
            children: [
              navPrev,
              Expanded(child: range),
              ?todayButton,
              navNext,
            ],
          )
        : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              navPrev,
              range,
              ?todayButton,
              navNext,
            ],
          );
  }
}
