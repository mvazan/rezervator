import 'package:flutter/material.dart';

/// Wraps an admin screen body so it doesn't stretch edge-to-edge on wide
/// (web/desktop) windows: centered, max 720 px. On phones it's a no-op.
class AdminBody extends StatelessWidget {
  const AdminBody({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: child,
      ),
    );
  }
}

/// Docks [button] in its own strip below [child] instead of Flutter's
/// floating [FloatingActionButton] mechanism, which overlays [child] rather
/// than sharing space with it — on a list long enough to fill the screen,
/// that puts the button on top of the last row. [AdminScaffold] wires every
/// admin list screen's `floatingActionButton` through this, one place
/// fixing the overlap everywhere instead of each screen working around it.
///
/// The shape (a scrollable region with the rest of the height, a button
/// strip below) is exactly what `report_screen.dart` (Docházka) already
/// hand-rolled for its Export CSV button — this is that pattern, extracted
/// so nobody else has to re-build it; `report_screen.dart` uses it too.
class ListActionBar extends StatelessWidget {
  const ListActionBar({
    super.key,
    required this.child,
    required this.button,
    this.alignment = Alignment.bottomRight,
  });

  /// The scrollable content — gets whatever height remains under [button].
  final Widget child;

  final Widget button;

  /// Where [button] sits across the strip's width. Bottom-right matches a
  /// [FloatingActionButton]'s usual spot; `report_screen.dart` centers its
  /// plain [FilledButton] instead.
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: child),
        // `minimum`, not a plain Padding: on a phone with a gesture nav bar
        // the OS inset alone can exceed 16px, and a fixed Padding would
        // then sit the button under the home-indicator strip.
        SafeArea(
          top: false,
          minimum: const EdgeInsets.all(16),
          child: Align(alignment: alignment, child: button),
        ),
      ],
    );
  }
}
