/// Shared chrome for the auth-family screens (login, register, waiting,
/// kiosk login): a centered card floating over a subtle radial gradient
/// backdrop, with the app logo in a gradient-bordered circle above it.
/// Purely presentational — callers keep their own Scaffold/AppBar/state;
/// this only wraps the body content, so no screen's behavior changes.
library;

import 'package:flutter/material.dart';

/// Radial gradient backdrop: indigo-tinted in light mode, slate→indigo in
/// dark — subtle enough that the centered [AuthCard] stays the focal point.
class AuthBackground extends StatelessWidget {
  const AuthBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.topCenter,
          radius: 1.4,
          colors: isDark
              ? const [Color(0xFF1E293B), Color(0xFF0F172A)]
              : [
                  const Color(0xFF6366F1).withValues(alpha: 0.06),
                  Colors.transparent,
                ],
        ),
      ),
      child: child,
    );
  }
}

/// Centered content card (max width 420, radius 20) — the auth screens'
/// shared frame around their (unchanged) form content.
class AuthCard extends StatelessWidget {
  const AuthCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(padding: const EdgeInsets.all(28), child: child),
          ),
        ),
      ),
    );
  }
}

/// App logo inside a circle with a 2px indigo→cyan gradient border.
class AuthLogo extends StatelessWidget {
  const AuthLogo({super.key, this.size = 96});

  final double size;

  static const _gradientColors = [Color(0xFF6366F1), Color(0xFF22D3EE)];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ringDiameter = size + 24;
    return Container(
      width: ringDiameter,
      height: ringDiameter,
      padding: const EdgeInsets.all(2),
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: _gradientColors),
      ),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: scheme.surface,
        ),
        alignment: Alignment.center,
        child: ClipOval(
          child: Image.asset(
            'assets/images/logo_circle.png',
            width: size,
            height: size,
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }
}
