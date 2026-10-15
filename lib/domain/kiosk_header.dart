/// The kiosk's header modules, the pure half (0082, `schedule_settings.
/// kiosk_header`): which module stands left of the centre (after the
/// clock), which right (before „Rezervace tréninku“), which is off, and
/// their order. Správa → Kiosk → Záhlaví edits it, the status bar lays it
/// out. The clock (always first) and today's matches (always in the
/// centre) are not listed. Pure Dart, unit-tested.
library;

import 'dart:convert' show jsonEncode;

import 'kiosk_layout.dart' show PanelSide;

/// A module of the kiosk's header. The name is its id in `kiosk_header`
/// — do not rename one.
enum KioskHeaderModule { weather, nameday, duty, notices }

/// The weather module's title while the admin has typed none (0082's
/// `kiosk_weather_title` null).
const kioskWeatherDefaultTitle = 'Počasí';

/// Whether a module's title already says „dnes“. The header says it once
/// (the user: „Dnes v Brně“, „Svátek mají“, „Službu má“): the modules after
/// the first one that does leave it out.
bool kioskTitleSaysToday(String title) =>
    RegExp(r'(^|[\s,(])dnes($|[\s,.:)])', caseSensitive: false)
        .hasMatch(title);

/// The admin's weather title after an earlier module said „Dnes“: a
/// leading „Dnes“ dropped and the rest capitalised („Dnes v Brně“ → „V
/// Brně“); any other title as typed.
String kioskTitleWithoutToday(String title) {
  final rest = RegExp(r'^\s*dnes[\s,:]+', caseSensitive: false)
      .firstMatch(title);
  if (rest == null || rest.end >= title.length) return title;
  final tail = title.substring(rest.end);
  return tail[0].toUpperCase() + tail.substring(1);
}

final _headerModulesById = {
  for (final m in KioskHeaderModule.values) m.name: m,
};

/// One module's entry: its side.
class KioskHeaderPlacement {
  const KioskHeaderPlacement({required this.id, required this.side, this.raw});

  /// The JSON id — a [KioskHeaderModule]'s name, or a module a newer app
  /// knows.
  final String id;
  final PanelSide side;

  /// The entry as read, for an id this build does not know: written back
  /// unchanged, so an older admin app never drops a newer module.
  final Map<String, Object?>? raw;

  /// Null for an id this build does not know.
  KioskHeaderModule? get module => _headerModulesById[id];

  Map<String, Object?> toJson() => raw ?? {'id': id, 'side': side.name};

  @override
  bool operator ==(Object other) =>
      other is KioskHeaderPlacement &&
      other.id == id &&
      other.side == side &&
      jsonEncode(other.raw) == jsonEncode(raw);

  @override
  int get hashCode => Object.hash(id, side);

  @override
  String toString() => '$id:${side.name}';
}

/// The header's layout. Immutable; the admin's edits return a new one,
/// which is PATCHed whole.
class KioskHeader {
  const KioskHeader({required this.modules});

  /// In order: a side lays its modules out left to right as listed here.
  final List<KioskHeaderPlacement> modules;

  /// 0082's column default, letter for letter (a test compares the two):
  /// the notices on the right, the rest off — what the old switches'
  /// defaults convert to.
  static const defaults = KioskHeader(
    modules: [
      KioskHeaderPlacement(id: 'weather', side: PanelSide.off),
      KioskHeaderPlacement(id: 'nameday', side: PanelSide.off),
      KioskHeaderPlacement(id: 'duty', side: PanelSide.off),
      KioskHeaderPlacement(id: 'notices', side: PanelSide.right),
    ],
  );

  /// Reads `kiosk_header`. Without a `modules` list (a row from before
  /// 0082) it is the defaults. Entries that are no object or have no id,
  /// and an id's second entry, are skipped; a bad side is off; an id this
  /// build does not know is kept as it was read; a module the list lacks
  /// is added at its end, off.
  factory KioskHeader.fromJson(Object? json) {
    final list = json is Map<String, Object?> ? json['modules'] : null;
    if (list is! List) return defaults;
    final seen = <String>{};
    final modules = <KioskHeaderPlacement>[];
    for (final entry in list) {
      if (entry is! Map<String, Object?>) continue;
      final id = entry['id'];
      if (id is! String || id.isEmpty || !seen.add(id)) continue;
      final side = PanelSide.values
          .where((s) => s.name == entry['side'])
          .firstOrNull;
      modules.add(
        KioskHeaderPlacement(
          id: id,
          side: side ?? PanelSide.off,
          raw: _headerModulesById[id] == null
              ? Map<String, Object?>.unmodifiable(entry)
              : null,
        ),
      );
    }
    for (final m in KioskHeaderModule.values) {
      if (!seen.contains(m.name)) {
        modules.add(KioskHeaderPlacement(id: m.name, side: PanelSide.off));
      }
    }
    return KioskHeader(modules: List.unmodifiable(modules));
  }

  Map<String, Object?> toJson() => {
    'modules': [for (final m in modules) m.toJson()],
  };

  /// The known modules on [side], in order.
  List<KioskHeaderPlacement> modulesOn(PanelSide side) => [
    for (final m in modules)
      if (m.module != null && m.side == side) m,
  ];

  PanelSide sideOf(KioskHeaderModule m) =>
      modules.where((p) => p.id == m.name).firstOrNull?.side ?? PanelSide.off;

  /// Whether [m] is in the header at all.
  bool isOn(KioskHeaderModule m) => sideOf(m) != PanelSide.off;

  /// [m] to [side] (or off). It keeps its place in the order, so it lands
  /// among that side's modules where it stood before.
  KioskHeader withSide(KioskHeaderModule m, PanelSide side) {
    final i = modules.indexWhere((p) => p.id == m.name);
    final next = [...modules];
    final placed = KioskHeaderPlacement(id: m.name, side: side);
    if (i < 0) {
      next.add(placed);
    } else {
      next[i] = placed;
    }
    return KioskHeader(modules: List.unmodifiable(next));
  }

  /// [m] [by] places left (negative) or right among the modules of its own
  /// side, stopping at the first and the last; the modules elsewhere — on
  /// the other side, off, unknown — keep their places. A module off does
  /// not move.
  KioskHeader moved(KioskHeaderModule m, int by) {
    final side = sideOf(m);
    if (side == PanelSide.off || by == 0) return this;
    final slots = [
      for (var i = 0; i < modules.length; i++)
        if (modules[i].module != null && modules[i].side == side) i,
    ];
    final from = slots.indexWhere((i) => modules[i].id == m.name);
    if (from < 0) return this;
    final to = (from + by).clamp(0, slots.length - 1);
    if (to == from) return this;
    final peers = [for (final i in slots) modules[i]];
    peers.insert(to, peers.removeAt(from));
    final next = [...modules];
    for (var k = 0; k < slots.length; k++) {
      next[slots[k]] = peers[k];
    }
    return KioskHeader(modules: List.unmodifiable(next));
  }

  @override
  bool operator ==(Object other) {
    if (other is! KioskHeader || other.modules.length != modules.length) {
      return false;
    }
    for (var i = 0; i < modules.length; i++) {
      if (other.modules[i] != modules[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(modules);

  @override
  String toString() => 'KioskHeader($modules)';
}

/// 0082's conversion of the four old switches, in Dart (tested against the
/// same cases as the tenancy suite): an old switch on puts the weather,
/// the name day and the duty left — they stood beside or under the clock —
/// and the notices right, where their line was.
KioskHeader kioskHeaderFromLegacy({
  required bool weather,
  required bool nameday,
  required bool dutyHeader,
  required bool noticesHeader,
}) {
  PanelSide on(bool v, PanelSide side) => v ? side : PanelSide.off;
  return KioskHeader(
    modules: [
      KioskHeaderPlacement(id: 'weather', side: on(weather, PanelSide.left)),
      KioskHeaderPlacement(id: 'nameday', side: on(nameday, PanelSide.left)),
      KioskHeaderPlacement(id: 'duty', side: on(dutyHeader, PanelSide.left)),
      KioskHeaderPlacement(
        id: 'notices',
        side: on(noticesHeader, PanelSide.right),
      ),
    ],
  );
}
