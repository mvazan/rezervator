import 'package:flutter/material.dart';

import '../../../domain/models.dart';

/// The week screen's top strip — it IS the app bar: title (where the width
/// allows), week navigation, action icons pinned to the right edge; a
/// narrow portrait phone stacks title/icons over the week selector.
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
  Widget build(BuildContext context) {
    // The top strip IS the app bar. A narrow portrait phone can't fit
    // title + week navigation + icons on one line, so it stacks them
    // (title/icons row, week selector under it); everything wider —
    // landscape phones and the web — keeps ONE line: title (where the
    // width allows), the week navigation next to it, action icons pinned
    // to the RIGHT edge.
    final width = MediaQuery.sizeOf(context).width;
    final portrait =
        MediaQuery.orientationOf(context) == Orientation.portrait;
    final stacked = portrait && width < 700;
    final title = Padding(
      padding: const EdgeInsets.only(left: 8, right: 4),
      child: Text(
        'Rezervátor',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleLarge,
      ),
    );
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: stacked
          ? Column(
              children: [
                Row(children: [title, const Spacer(), ...trailing]),
                Row(
                  children: [
                    navPrev,
                    Expanded(child: range),
                    ?todayButton,
                    navNext,
                  ],
                ),
              ],
            )
          : Row(
              children: [
                // | Rezervátor      < datum – datum >      admin profil |
                // The title must NOT be a flex child: Flexible would claim
                // an equal flex share as the Expanded nav, and its unused
                // allocation becomes dead space at the row's end — pushing
                // the icons to the middle instead of the right edge.
                if (width >= 700) title,
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      navPrev,
                      range,
                      ?todayButton,
                      navNext,
                    ],
                  ),
                ),
                ...trailing,
              ],
            ),
    );
  }
}
