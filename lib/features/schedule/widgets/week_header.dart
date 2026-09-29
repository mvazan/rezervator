import 'package:flutter/material.dart';

import '../../../domain/duties.dart';
import '../../../domain/models.dart';
import 'home_header.dart';
import 'week_range_nav.dart';

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
    this.duty,
    this.onDutyTap,
  });

  final Day monday;

  /// 0 = this week → no "dnes" button.
  final int weekOffset;

  /// Week navigation: -1 / +1 a week, 0 = today.
  final void Function(int delta) onGo;

  /// Action icons pinned to the right edge — in landscape the shell has no
  /// AppBar and parks its icons here (one shared top line).
  final List<Widget> trailing;

  /// Who serves in the canteen this week (0050): a `labelSmall` line under
  /// the range, tinted when it is my duty; null for no line.
  final DutyHeader? duty;

  /// Tapping the duty line — the calendar opens Klubovna → Služby.
  final VoidCallback? onDutyTap;

  @override
  Widget build(BuildContext context) => HomeHeader(
        trailing: trailing,
        middle: (stacked) => _weekNav(context, stacked),
      );

  // On one line the week selector sits centred between the title and the
  // icons; stacked it has the second line to itself, so the range can take
  // all the width between the two arrows.
  Widget _weekNav(BuildContext context, bool stacked) {
    final nav = WeekRangeNav(
      monday: monday,
      weekOffset: weekOffset,
      onGo: onGo,
      stacked: stacked,
    );
    final duty = this.duty;
    if (duty == null) return nav;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        nav,
        // A button to a screen reader (when it opens something); the hit
        // area spans the nav's width and is 32dp tall, the line itself
        // stays one small centred row.
        Semantics(
          button: onDutyTap != null,
          child: InkWell(
            onTap: onDutyTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: double.infinity,
                minHeight: 32,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Center(
                  widthFactor: 1,
                  heightFactor: 1,
                  child: Text(
                    duty.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: duty.mine
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                      fontWeight: duty.mine ? FontWeight.w700 : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
