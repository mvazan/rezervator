/// Shared schedule cell: one widget renders every slot in both the app's
/// week list and the kiosk's week view. Purely presentational — all booking
/// policy (canBook/canCancel/isAdmin gating) stays with the caller, which
/// resolves a display name and a single [onTap] callback (or null to render
/// inert) before constructing the tile.
library;

import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../domain/models.dart';
import '../../../domain/schedule.dart';

enum SlotTileSize { compact, large }

class SlotTile extends StatelessWidget {
  const SlotTile({
    super.key,
    required this.state,
    required this.size,
    this.playerName,
    this.isMine = false,
    this.quiet = false,
    this.onTap,
  });

  final SlotState state;
  final SlotTileSize size;

  /// Resolved display name for [ReservedSlot] cells (mine or other).
  final String? playerName;

  /// Whether a [ReservedSlot] belongs to the caller — bolds the name and
  /// tints the cell with the primary container instead of the neutral one.
  final bool isMine;

  /// For a bookable [FreeSlot]: true when the cell is only bookable through
  /// the admin exemption (inPast/beyondHorizon) rather than the ordinary
  /// player rules — renders the '+' at a quieter alpha so admins can tell
  /// at a glance which slots are normally locked.
  final bool quiet;

  /// Tap handler; null renders the cell inert (no InkWell/ink response).
  final VoidCallback? onTap;

  bool get _compact => size == SlotTileSize.compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final minHeight = _compact ? 44.0 : 56.0;

    switch (state) {
      case MatchSlot():
        return _shell(
          minHeight: minHeight,
          decoration: BoxDecoration(
            color: scheme.errorContainer.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(_compact ? 8 : 12),
          ),
          child: Text(
            'Zápas',
            style: TextStyle(
              fontSize: _compact ? 11 : 13,
              fontWeight: FontWeight.w600,
              color: scheme.onErrorContainer,
            ),
          ),
        );
      case RentedSlot(:final rental):
        return _shell(
          minHeight: minHeight,
          decoration: BoxDecoration(
            color: scheme.tertiaryContainer.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(_compact ? 8 : 12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            rental.renterName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: _compact ? 10 : 12,
              color: scheme.onTertiaryContainer,
            ),
          ),
        );
      case ReservedSlot():
        final name = playerName ?? '?';
        final nameStyle = TextStyle(
          fontSize: _compact ? 10 : 12,
          fontWeight: isMine ? FontWeight.w700 : FontWeight.w500,
          color: isMine ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
        );
        final content = isMine || _compact
            ? Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: nameStyle,
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: scheme.surfaceContainerHighest,
                    child: Text(
                      initialsOf(name),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: nameStyle,
                  ),
                ],
              );
        return _shell(
          minHeight: minHeight,
          onTap: onTap,
          decoration: BoxDecoration(
            color: isMine
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(_compact ? 8 : 12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: content,
        );
      case FreeSlot():
        if (onTap == null) {
          return _shell(
            minHeight: minHeight,
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(_compact ? 8 : 12),
            ),
          );
        }
        return _shell(
          minHeight: minHeight,
          onTap: onTap,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_compact ? 8 : 12),
            border: Border.all(
              color: scheme.primary.withValues(alpha: quiet ? 0.25 : 0.45),
              width: 1.2,
            ),
          ),
          child: Icon(
            Icons.add,
            size: _compact ? 18 : 22,
            color: scheme.primary.withValues(alpha: quiet ? 0.25 : 0.45),
          ),
        );
    }
  }

  Widget _shell({
    required double minHeight,
    Widget? child,
    BoxDecoration? decoration,
    EdgeInsetsGeometry? padding,
    VoidCallback? onTap,
  }) {
    final body = Container(
      constraints: BoxConstraints(minHeight: minHeight),
      alignment: Alignment.center,
      padding: padding,
      decoration: decoration,
      child: child,
    );
    if (onTap == null) return body;
    return InkWell(
      onTap: onTap,
      borderRadius: decoration?.borderRadius?.resolve(TextDirection.ltr),
      child: body,
    );
  }
}

/// Resolves the same booking/cancel policy the original inline `_SlotCell`
/// computed (canBook/canCancel, admin exemptions, name lookup) into the slim
/// [SlotTile] contract: a display name, isMine/quiet flags, and a single
/// resolved tap handler (or null to render the cell inert). Shared by the
/// week list view (compact tiles) and the day pager view (large tiles) so
/// the policy has exactly one implementation regardless of layout.
Widget slotTileFor({
  required OpenDay day,
  required TimeBlock block,
  required int lane,
  required SlotTileSize size,
  required Profile? me,
  required int myCount,
  required ScheduleSettings settings,
  required Map<String, String> nameById,
  required bool interactive,
  required void Function(Day, TimeBlock, int lane) onBook,
  required void Function(Day, TimeBlock, Reservation, {required bool ownFuture})
  onCancel,
}) {
  final state = day.slot(block.id, lane);
  switch (state) {
    case MatchSlot():
    case RentedSlot():
      return SlotTile(state: state, size: size);
    case ReservedSlot(:final reservation):
      final isMine = me != null && reservation.playerId == me.id;
      final name = nameById[reservation.playerId] ?? '?';
      // Pozn.: RPC dovoluje rezervovat i dnešní už začatý blok (kontroluje
      // jen p_date < today); klient ho schovává jako inPast. Kiosk může
      // chtít tuto benevolenci využít.
      final ownFuture = isMine && canCancel(state: state, myPlayerId: me.id);
      // Admins may cancel any reservation (own/foreign, past/future); a
      // non-admin may only cancel their own not-yet-started one.
      final cancellable =
          interactive && me != null && (me.isAdmin || ownFuture);
      return SlotTile(
        state: state,
        size: size,
        playerName: name,
        isMine: isMine,
        onTap: cancellable
            ? () => onCancel(day.date, block, reservation, ownFuture: ownFuture)
            : null,
      );
    case FreeSlot():
      final isAdmin = me?.isAdmin ?? false;
      final bookable =
          interactive &&
          me != null &&
          canBook(
            state: state,
            myActiveCount: myCount,
            settings: settings,
            isAdmin: isAdmin,
          );
      // Cells only bookable through the admin exemption (inPast or
      // beyondHorizon, which a regular player could never book) render the
      // '+' quieter, so admins can tell at a glance which slots are
      // ordinarily locked.
      final normallyBookable = canBook(
        state: state,
        myActiveCount: myCount,
        settings: settings,
        isAdmin: false,
      );
      return SlotTile(
        state: state,
        size: size,
        quiet: !normallyBookable,
        onTap: bookable ? () => onBook(day.date, block, lane) : null,
      );
  }
}
