/// Shared schedule cell: one widget renders every slot — the app's week
/// calendar ([SlotTileSize.compact]), its day pager ([SlotTileSize.large])
/// and the kiosk board's lane rows ([SlotTileSize.row], digit inside the
/// cell). Purely presentational — all booking policy (canBook/canCancel/
/// isAdmin gating) stays with the caller, which resolves a display name and
/// a single [onTap] callback (or null to render inert) before constructing
/// the tile.
library;

import 'package:flutter/material.dart';

import '../../../domain/labels.dart';
import '../../../domain/models.dart';
import '../../../domain/palette.dart';
import '../../../domain/schedule.dart';
import '../schedule_callbacks.dart';

enum SlotTileSize {
  /// Week calendar: one clipped line, lane digit drawn beside the tile.
  compact,

  /// Day pager: two lines / avatar, roomier.
  large,

  /// Kiosk board: a single rounded cell with the lane digit inside, 11px
  /// text, a literal '＋' when bookable.
  row,
}

class SlotTile extends StatelessWidget {
  const SlotTile({
    super.key,
    required this.state,
    required this.size,
    this.playerName,
    this.isMine = false,
    this.clubColorIndex = -1,
    this.quiet = false,
    this.onTap,
    this.laneDigit,
  });

  final SlotState state;
  final SlotTileSize size;

  /// Resolved display name for [ReservedSlot] cells (mine or other).
  final String? playerName;

  /// Whether a [ReservedSlot] belongs to the caller — bolds the name and
  /// draws a primary outline; without a club the cell also falls back to
  /// the primary container instead of the neutral tint.
  final bool isMine;

  /// Club palette index (spec §5) of a [ReservedSlot]'s player — the
  /// caller's own included: 0–11 tints the cell with that club's colour,
  /// anything else (-1 = no club) keeps the neutral surface tint (primary
  /// for "mine"). The board is read by club colour, so an own booking must
  /// not break the pattern.
  final int clubColorIndex;

  /// For a bookable [FreeSlot]: true when the cell is only bookable through
  /// the admin exemption (inPast/beyondHorizon) rather than the ordinary
  /// player rules — renders the '+' at a quieter alpha so admins can tell
  /// at a glance which slots are normally locked.
  final bool quiet;

  /// Tap handler; null renders the cell inert (no InkWell/ink response).
  final VoidCallback? onTap;

  /// [SlotTileSize.row] only: the lane number drawn inside the cell.
  final int? laneDigit;

  bool get _compact => size == SlotTileSize.compact;

  @override
  Widget build(BuildContext context) {
    if (size == SlotTileSize.row) return _buildRow(context);
    final scheme = Theme.of(context).colorScheme;
    final minHeight = _compact ? 44.0 : 56.0;

    switch (state) {
      case PrioritySlotState(:final slot):
        // Lane-scoped slots are the only PrioritySlotState producers in
        // rendered blocks (whole-alley ones cancel the block outright), so
        // the cell must carry the TYPE's name and colour — 'Sanitární den'
        // must not read as a match. Mirrors the kiosk's lane row.
        final (bg, fg) = clubTint(slot.type.colorIndex, scheme.brightness,
            fallbackBg: scheme.errorContainer.withValues(alpha: 0.6),
            fallbackFg: scheme.onErrorContainer);
        return _shell(
          minHeight: minHeight,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(_compact ? 8 : 12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            slotEventLabel(slot),
            maxLines: _compact ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: _compact ? 10 : 12,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        );
      case RentedSlot(:final rental):
        // Rental colour (spec §3): a 0–11 palette index paints the cell with
        // that club colour; the default (-2) keeps today's amber tertiary
        // tint.
        final (bg, fg) = clubTint(rental.color, scheme.brightness,
            fallbackBg: scheme.tertiaryContainer.withValues(alpha: 0.7),
            fallbackFg: scheme.onTertiaryContainer);
        // Admins tap a rented cell to edit that day's rental (resolved by
        // slotTileFor); everyone else gets null and an inert cell.
        return _shell(
          minHeight: minHeight,
          onTap: onTap,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(_compact ? 8 : 12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            rental.renterName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: _compact ? 10 : 12, color: fg),
          ),
        );
      case ReservedSlot():
        final name = playerName ?? '?';
        // Every reservation is tinted by the player's club colour (spec §5),
        // the caller's own included — the board is read by club. "Mine"
        // keeps its own cue on top (bold name, primary outline) and only
        // falls back to primaryContainer when the player has no club.
        final (cellBg, cellFg) = clubTint(
            clubColorIndex, scheme.brightness,
            fallbackBg: isMine
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            fallbackFg: isMine
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant);
        final nameStyle = TextStyle(
          fontSize: _compact ? 10 : 12,
          fontWeight: isMine ? FontWeight.w700 : FontWeight.w500,
          color: cellFg,
        );
        // The name alone. Compact cells (the fit-width week grid) get a
        // single clipped line so a long name never overflows the narrow
        // flexed column; the roomier large "mine" tile keeps two lines. Other
        // players' large tiles used to stack an initials avatar over the
        // name, which on a portrait phone read as two rows ("FE" / "FERI").
        final content = Text(
          name,
          maxLines: !_compact && isMine ? 2 : 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: nameStyle,
        );
        return _shell(
          minHeight: minHeight,
          onTap: onTap,
          decoration: BoxDecoration(
            color: cellBg,
            borderRadius: BorderRadius.circular(_compact ? 8 : 12),
            border: isMine
                ? Border.all(color: scheme.primary, width: 1.5)
                : null,
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

  /// The kiosk lane row: every slot is its own bounded rounded cell (margin
  /// + radius) inside the block card; a free non-bookable slot stays a quiet
  /// fill so the card reads as one unit at a distance.
  Widget _buildRow(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (state) {
      case RentedSlot(:final rental):
        // Rental colour (spec §3): a 0–11 index paints the row with that
        // palette colour; the default (-2) keeps the amber tertiary tint.
        final (bg, fg) = clubTint(rental.color, scheme.brightness,
            fallbackBg: scheme.tertiaryContainer.withValues(alpha: 0.5),
            fallbackFg: scheme.onTertiaryContainer);
        return _rowShell(
          context,
          background: bg,
          child: Text(
            rentalLabel(rental),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: fg),
          ),
        );
      case ReservedSlot():
        // Every reservation carries the player's club colour (spec §5), the
        // selected player's own included — the board is read by club. "Mine"
        // keeps a bold name and a primary outline; only a club-less player
        // falls back to the primaryContainer highlight.
        final (cellBg, cellFg) = clubTint(clubColorIndex, scheme.brightness,
            fallbackBg: isMine
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            fallbackFg: isMine
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant);
        return _rowShell(
          context,
          background: cellBg,
          border: isMine
              ? Border.all(color: scheme.primary, width: 1.5)
              : null,
          onTap: onTap,
          child: Text(
            playerName ?? '?',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isMine ? FontWeight.w700 : FontWeight.w500,
              color: cellFg,
            ),
          ),
        );
      case FreeSlot():
        final bookable = onTap != null;
        return _rowShell(
          context,
          onTap: onTap,
          border: bookable
              ? Border.all(color: scheme.secondary.withValues(alpha: 0.5))
              : null,
          child: bookable
              ? Text(
                  '＋',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: scheme.secondary,
                  ),
                )
              : null,
        );
      case PrioritySlotState(:final slot):
        // A LANE-SCOPED priority slot blocking just this row — or, briefly,
        // an unresolved-type slot (renders like a match but doesn't cancel
        // blocks until its type row streams in).
        final (bg, fg) = clubTint(slot.type.colorIndex, scheme.brightness,
            fallbackBg: scheme.errorContainer.withValues(alpha: 0.6),
            fallbackFg: scheme.onErrorContainer);
        return _rowShell(
          context,
          background: bg,
          child: Text(
            slotEventLabel(slot),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: fg),
          ),
        );
    }
  }

  Widget _rowShell(
    BuildContext context, {
    Color? background,
    BoxBorder? border,
    VoidCallback? onTap,
    Widget? child,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(6);
    final body = Container(
      margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 1.5),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: background ?? scheme.surfaceContainerLow.withValues(alpha: 0.35),
        border: border,
        borderRadius: radius,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            child: Text(
              '${laneDigit ?? ''}',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (child != null) Expanded(child: child),
        ],
      ),
    );
    if (onTap == null) return body;
    return InkWell(onTap: onTap, borderRadius: radius, child: body);
  }

}

/// Resolves the same booking/cancel policy the original inline `_SlotCell`
/// computed (canBook/canCancel, admin exemptions, name lookup) — plus the
/// admin's rental tap ([SlotCallbacks.onRental]) — into the slim
/// [SlotTile] contract: a display name, isMine/quiet flags, and a single
/// resolved tap handler (or null to render the cell inert). Shared by the
/// week calendar view (compact tiles) and the day pager view (large tiles) so
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
  required Map<String, int> clubColorById,
  required bool interactive,
  required SlotCallbacks slot,
}) {
  final state = day.slot(block.id, lane);
  switch (state) {
    case PrioritySlotState():
      return SlotTile(state: state, size: size);
    case RentedSlot(:final rental):
      // Admins tap a rented cell to edit that day's rental (a weekly one
      // opens its "jen tento den" exception dialog); for everyone else the
      // cell stays inert. Copied to a local first — a nullable field never
      // promotes on the null check.
      final onRental = slot.onRental;
      return SlotTile(
        state: state,
        size: size,
        onTap: interactive && onRental != null
            ? () => onRental(day.date, rental)
            : null,
      );
    case ReservedSlot(:final reservation):
      final isMine = me != null && reservation.playerId == me.id;
      final name = nameById[reservation.playerId] ?? '?';
      // The caller's own pick (Můj profil) wins over the club colour, but
      // only in their own view: everyone else keeps seeing the club.
      final ownColor = me?.ownColor ?? -1;
      final tint = isMine && ownColor >= 0
          ? ownColor
          : clubColorById[reservation.playerId] ?? -1;
      // Pozn.: RPC dovoluje rezervovat i dnešní už začatý blok (kontroluje
      // jen p_date < today); klient ho schovává jako inPast. Kiosk může
      // chtít tuto benevolenci využít.
      final ownFuture = isMine && canCancel(state: state, myPlayerId: me.id);
      // Admins may cancel any reservation (own/foreign, past/future); a
      // non-admin may only cancel their own not-yet-started one.
      final cancellable = interactive &&
          me != null &&
          canCancel(state: state, myPlayerId: me.id, isAdmin: me.isAdmin);
      return SlotTile(
        state: state,
        size: size,
        playerName: name,
        isMine: isMine,
        clubColorIndex: tint,
        onTap: cancellable
            ? () =>
                slot.onCancel(day.date, block, reservation, ownFuture: ownFuture)
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
        onTap: bookable ? () => slot.onBook(day.date, block, lane) : null,
      );
  }
}
