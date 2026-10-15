/// Primary call-to-action button: indigo → cyan gradient fill with a ripple,
/// used for the app's main actions (e.g. kiosk "Rezervovat").
library;

import 'package:flutter/material.dart';

import '../theme.dart';

class GradientButton extends StatelessWidget {
  const GradientButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.minHeight = 48,
    this.fontSize,
    this.fontWeight = FontWeight.w700,
    this.iconSize,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final IconData? icon;
  final double minHeight;

  /// The label's size; null = the ambient text style's. The kiosk's
  /// „Rezervace tréninku“ is its main action and says so in size.
  final double? fontSize;
  final FontWeight fontWeight;

  /// The icon's size; null = the ambient icon theme's.
  final double? iconSize;


  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final radius = BorderRadius.circular(12);
    // White reads fine on the gradient's indigo end but drowns on the cyan
    // end in a light theme — there the label flips to deep indigo.
    final foreground = scheme.brightness == Brightness.dark
        ? Colors.white
        : const Color(0xFF1E1B4B);

    final label = DefaultTextStyle.merge(
      style: TextStyle(
        color: foreground,
        fontSize: fontSize,
        fontWeight: fontWeight,
      ),
      child: child,
    );

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(
            icon,
            size: iconSize,
            color: enabled
                ? foreground
                : scheme.onSurface.withValues(alpha: 0.38),
          ),
          SizedBox(width: (iconSize ?? 24) / 3),
        ],
        label,
      ],
    );

    return Ink(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: enabled
            ? const LinearGradient(colors: brandGradientColors)
            : null,
        color: enabled ? null : scheme.onSurface.withValues(alpha: 0.12),
      ),
      child: InkWell(
        onTap: onPressed,
        borderRadius: radius,
        child: Container(
          constraints: BoxConstraints(minHeight: minHeight),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: enabled
              ? content
              : DefaultTextStyle.merge(
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.38),
                    fontWeight: fontWeight,
                  ),
                  child: content,
                ),
        ),
      ),
    );
  }
}
