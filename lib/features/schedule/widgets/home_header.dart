import 'package:flutter/material.dart';

/// The home's top strip — it IS the app bar for both views: the app title
/// (where the width allows), the view's own controls in the middle, action
/// icons pinned to the right edge. There is no AppBar above it.
///
/// Both views build this same strip, and that is the point: the profile and
/// admin icons keep their exact place when the tabs switch. A header that
/// shifted would make them a moving target and read as two unrelated
/// screens. The title says the app's name rather than the view's — which
/// view you are on is what the tabs (or the rail) already say.
///
/// A narrow portrait phone can't fit title + controls + icons on one line,
/// so it stacks them: title/icons on top, the view's controls on a line of
/// their own. [middle] is therefore told which layout it landed in.
class HomeHeader extends StatelessWidget {
  const HomeHeader({super.key, required this.trailing, this.middle});

  /// The view's own controls: the week navigation on the calendar, nothing
  /// on Můj přehled. `stacked` is true in the two-row layout, where these
  /// controls own the whole second line instead of sharing the first.
  final Widget Function(bool stacked)? middle;

  /// Action icons pinned to the right edge — the shell parks its icons here
  /// so both views share ONE top line.
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => _build(context, constraints.maxWidth),
      );

  // [width] is what this strip actually got, not what the screen has: on a
  // wide-enough screen the shell parks a navigation rail to the left, and
  // measuring the screen would keep the title on a strip too narrow to hold
  // it — the row then overflows by the few pixels the rail took.
  Widget _build(BuildContext context, double width) {
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: stacked
          ? Column(
              children: [
                Row(children: [title, const Spacer(), ...trailing]),
                ?middle?.call(true),
              ],
            )
          : Row(
              children: [
                // | Rezervátor      < datum – datum >      admin profil |
                // The title must NOT be a flex child: Flexible would claim
                // an equal flex share as the Expanded middle, and its unused
                // allocation becomes dead space at the row's end — pushing
                // the icons to the middle instead of the right edge.
                if (width >= 700) title,
                Expanded(
                  child: middle?.call(false) ?? const SizedBox.shrink(),
                ),
                ...trailing,
              ],
            ),
    );
  }
}
