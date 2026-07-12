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
