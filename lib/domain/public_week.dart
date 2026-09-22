/// The public board's data (0043): one week of one published alley as
/// `public_week` returns it, and the admin's own setting
/// (`my_public_overview`). Pure Dart.
///
/// The server hands out no names, so the board has none to show: an
/// occupied lane arrives as a bare cell and becomes a synthetic
/// [Reservation] named [publicOccupiedLabel] in its club colour — the
/// schedule code (`buildWeekSchedule`, the tiles) then renders it exactly as
/// it renders a real one.
library;

import 'models.dart';

/// What every occupied lane and every rental reads on the public board.
const publicOccupiedLabel = 'Obsazeno';

final _epoch = DateTime.utc(1970);

/// One occupied lane: where, and the holder's club colour (−1 = no club).
class PublicCell {
  const PublicCell({
    required this.blockId,
    required this.date,
    required this.lane,
    required this.clubColor,
  });

  final String blockId;
  final Day date;
  final int lane;
  final int clubColor;

  /// Stands in for both the reservation and the player id — unique per
  /// cell, and it names no one.
  String get id => 'pub-$blockId-${date.toSql()}-$lane';

  factory PublicCell.fromJson(Map<String, dynamic> json) => PublicCell(
        blockId: json['block_id'] as String,
        date: Day.parse(json['date'] as String),
        lane: json['lane'] as int,
        clubColor: json['club_color'] as int? ?? -1,
      );
}

/// The cells as live reservations the board can draw.
List<Reservation> publicReservations(List<PublicCell> cells) => [
      for (final c in cells)
        Reservation(
          id: c.id,
          playerId: c.id,
          date: c.date,
          blockId: c.blockId,
          lane: c.lane,
          createdVia: 'public',
          createdAt: _epoch,
        ),
    ];

class PublicWeek {
  const PublicWeek({
    required this.tenantName,
    required this.settings,
    required this.blocks,
    required this.overrides,
    required this.prioritySlots,
    required this.rentals,
    required this.reservations,
    required this.nameById,
    required this.clubColorById,
  });

  final String tenantName;
  final ScheduleSettings settings;
  final List<TimeBlock> blocks;
  final List<DayOverride> overrides;
  final List<PrioritySlot> prioritySlots;
  final List<Rental> rentals;
  final List<Reservation> reservations;
  final Map<String, String> nameById;
  final Map<String, int> clubColorById;

  factory PublicWeek.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> rows(String key) => [
          for (final row in json[key] as List? ?? const [])
            Map<String, dynamic>.from(row as Map),
        ];
    final typeById = {
      for (final t in rows('slot_types').map(PrioritySlotType.fromJson)) t.id: t,
    };
    final cells = rows('occupied').map(PublicCell.fromJson).toList();
    final settings = json['settings'];
    return PublicWeek(
      tenantName: json['tenant_name'] as String? ?? '',
      settings: settings == null
          ? ScheduleSettings.defaults
          : ScheduleSettings.fromJson(Map<String, dynamic>.from(settings as Map)),
      blocks: rows('blocks').map(TimeBlock.fromJson).toList(),
      overrides: rows('overrides').map(DayOverride.fromJson).toList(),
      prioritySlots: [
        for (final row in rows('priority_slots')) PrioritySlot.fromJson(row, typeById),
      ],
      rentals: [
        for (final row in rows('rentals'))
          Rental.fromJson({...row, 'renter_name': publicOccupiedLabel}),
      ],
      reservations: publicReservations(cells),
      nameById: {for (final c in cells) c.id: publicOccupiedLabel},
      clubColorById: {for (final c in cells) c.id: c.clubColor},
    );
  }
}

/// The admin's view of their own alley's setting.
class PublicOverview {
  const PublicOverview({
    required this.slug,
    required this.enabled,
    required this.tenantName,
  });

  final String? slug;
  final bool enabled;

  /// The slug suggestion is made from it.
  final String tenantName;

  factory PublicOverview.fromJson(Map<String, dynamic> json) => PublicOverview(
        slug: json['public_slug'] as String?,
        enabled: json['public_enabled'] as bool? ?? false,
        tenantName: json['tenant_name'] as String? ?? '',
      );
}
