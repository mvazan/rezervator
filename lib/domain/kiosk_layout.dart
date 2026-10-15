/// The kiosk's two panels, the pure half (0077, `schedule_settings.
/// kiosk_panels`): how many day columns each panel covers and whether it
/// rests open, and which module goes into which panel — with its share of
/// the panel's height and its place in the order. Správa → Kiosk edits it,
/// the kiosk lays it out. Pure Dart, unit-tested.
library;

import 'dart:convert' show jsonEncode;

/// A module of the kiosk's panels. The name is its id in `kiosk_panels`
/// — do not rename one.
enum KioskModule { duty, notices, matches, guide, week }

/// Where a module goes: nowhere, the left panel or the right one. The name
/// is its `side` in `kiosk_panels` — do not rename one.
enum PanelSide { off, left, right }

/// The share of its panel's height a module starts with — also what a
/// module gets back when the stored layout does not have it yet (0077's
/// default layout says the same).
int kioskModuleDefaultShare(KioskModule m) => switch (m) {
  KioskModule.duty => 30,
  KioskModule.notices => 40,
  KioskModule.matches => 60,
  KioskModule.guide => 45,
  KioskModule.week => 55,
};

/// The bounds `kiosk_panels_valid` (0077) holds a panel's width and a
/// module's share to.
const kioskPanelMinDays = 1;
const kioskPanelMaxDays = 13;
const kioskModuleMinShare = 5;
const kioskModuleMaxShare = 95;

final _modulesById = {for (final m in KioskModule.values) m.name: m};

int _clampInt(int value, int min, int max) =>
    value < min ? min : (value > max ? max : value);

/// A whole JSON number (`2` or `2.0`), else null — the check's test
/// `v::numeric = trunc(v::numeric)`.
int? _whole(Object? v) =>
    v is num && v.isFinite && v == v.truncate() ? v.toInt() : null;

/// One panel: how many of the board's day columns it covers when open, and
/// whether it is open when nobody has touched the kiosk for a while.
class KioskPanel {
  const KioskPanel({required this.days, required this.open});

  final int days;
  final bool open;

  static const _fallback = KioskPanel(days: 2, open: false);

  /// Each field on its own: a bad or missing one is the default's.
  static KioskPanel _fromJson(Object? json) {
    if (json is! Map<String, Object?>) return _fallback;
    final days = _whole(json['days']);
    final open = json['open'];
    return KioskPanel(
      days: days != null && days >= kioskPanelMinDays &&
              days <= kioskPanelMaxDays
          ? days
          : _fallback.days,
      open: open is bool ? open : _fallback.open,
    );
  }

  Map<String, Object?> toJson() => {'days': days, 'open': open};

  @override
  bool operator ==(Object other) =>
      other is KioskPanel && other.days == days && other.open == open;

  @override
  int get hashCode => Object.hash(days, open);

  @override
  String toString() => 'KioskPanel($days, open: $open)';
}

/// One module's entry in the layout: its panel and its share of that
/// panel's height (a flex weight — the shares of a panel need not add up
/// to 100, they are spread over its whole height).
class KioskModulePlacement {
  const KioskModulePlacement({
    required this.id,
    required this.side,
    required this.share,
    this.raw,
  });

  /// The JSON id — a [KioskModule]'s name, or a module a newer app knows.
  final String id;
  final PanelSide side;

  /// 5–95.
  final int share;

  /// The entry as read, for an id this build does not know: written back
  /// unchanged, so an older admin app never drops a newer module.
  final Map<String, Object?>? raw;

  /// Null for an id this build does not know.
  KioskModule? get module => _modulesById[id];

  KioskModulePlacement _with({PanelSide? side, int? share}) =>
      KioskModulePlacement(
        id: id,
        side: side ?? this.side,
        share: share ?? this.share,
        raw: raw,
      );

  Map<String, Object?> toJson() =>
      raw ?? {'id': id, 'side': side.name, 'share': share};

  @override
  bool operator ==(Object other) =>
      other is KioskModulePlacement &&
      other.id == id &&
      other.side == side &&
      other.share == share &&
      jsonEncode(other.raw) == jsonEncode(raw);

  @override
  int get hashCode => Object.hash(id, side, share);

  @override
  String toString() => '$id:${side.name}:$share';
}

/// The whole layout: both panels and every module's place. Immutable; the
/// admin's edits return a new one, which is PATCHed whole.
class KioskPanels {
  const KioskPanels({
    required this.left,
    required this.right,
    required this.modules,
  });

  final KioskPanel left, right;

  /// In order: a panel stacks its modules top to bottom as listed here.
  final List<KioskModulePlacement> modules;

  /// 0077's column default, letter for letter (a test compares the two):
  /// both panels two days wide and closed, the notices and the matches in
  /// the right one — what the kiosk showed before there were two.
  static const defaults = KioskPanels(
    left: KioskPanel(days: 2, open: false),
    right: KioskPanel(days: 2, open: false),
    modules: [
      KioskModulePlacement(id: 'duty', side: PanelSide.off, share: 30),
      KioskModulePlacement(id: 'notices', side: PanelSide.right, share: 40),
      KioskModulePlacement(id: 'matches', side: PanelSide.right, share: 60),
      KioskModulePlacement(id: 'guide', side: PanelSide.off, share: 45),
      KioskModulePlacement(id: 'week', side: PanelSide.off, share: 55),
    ],
  );

  /// Reads `kiosk_panels`. Bad values fall back field by field: a panel to
  /// two closed days, a side to off, a share to the module's default.
  /// Without a `modules` list at all (a row from before 0077) the modules
  /// are the defaults'. Entries that are no object or have no id, and an
  /// id's second entry, are skipped; an id this build does not know is kept
  /// as it was read; a module the list lacks is added at its end, off, with
  /// its default share.
  factory KioskPanels.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const <String, Object?>{};
    final list = map['modules'];
    if (list is! List) {
      return KioskPanels(
        left: KioskPanel._fromJson(map['left']),
        right: KioskPanel._fromJson(map['right']),
        modules: defaults.modules,
      );
    }
    final seen = <String>{};
    final modules = <KioskModulePlacement>[];
    for (final entry in list) {
      if (entry is! Map<String, Object?>) continue;
      final id = entry['id'];
      if (id is! String || id.isEmpty || !seen.add(id)) continue;
      final module = _modulesById[id];
      final side = PanelSide.values
          .where((s) => s.name == entry['side'])
          .firstOrNull;
      final share = _whole(entry['share']);
      modules.add(
        KioskModulePlacement(
          id: id,
          side: side ?? PanelSide.off,
          share: share != null &&
                  share >= kioskModuleMinShare &&
                  share <= kioskModuleMaxShare
              ? share
              : (module == null ? 50 : kioskModuleDefaultShare(module)),
          raw: module == null ? Map<String, Object?>.unmodifiable(entry) : null,
        ),
      );
    }
    for (final m in KioskModule.values) {
      if (seen.contains(m.name)) continue;
      modules.add(
        KioskModulePlacement(
          id: m.name,
          side: PanelSide.off,
          share: kioskModuleDefaultShare(m),
        ),
      );
    }
    return KioskPanels(
      left: KioskPanel._fromJson(map['left']),
      right: KioskPanel._fromJson(map['right']),
      modules: List.unmodifiable(modules),
    );
  }

  Map<String, Object?> toJson() => {
    'left': left.toJson(),
    'right': right.toJson(),
    'modules': [for (final m in modules) m.toJson()],
  };

  /// The left or the right panel; off is no panel.
  KioskPanel panel(PanelSide side) => switch (side) {
    PanelSide.left => left,
    PanelSide.right => right,
    PanelSide.off => throw ArgumentError.value(side, 'side', 'is no panel'),
  };

  /// The known modules on [side], in order.
  List<KioskModulePlacement> modulesOn(PanelSide side) => [
    for (final m in modules)
      if (m.module != null && m.side == side) m,
  ];

  KioskModulePlacement? _placement(KioskModule m) =>
      modules.where((p) => p.id == m.name).firstOrNull;

  PanelSide sideOf(KioskModule m) => _placement(m)?.side ?? PanelSide.off;

  int shareOf(KioskModule m) =>
      _placement(m)?.share ?? kioskModuleDefaultShare(m);

  KioskPanels _withModules(List<KioskModulePlacement> next) =>
      KioskPanels(left: left, right: right, modules: List.unmodifiable(next));

  KioskPanels _change(
    KioskModule m,
    KioskModulePlacement Function(KioskModulePlacement p) change,
  ) {
    final i = modules.indexWhere((p) => p.id == m.name);
    final next = [...modules];
    if (i < 0) {
      next.add(
        change(
          KioskModulePlacement(
            id: m.name,
            side: PanelSide.off,
            share: kioskModuleDefaultShare(m),
          ),
        ),
      );
    } else {
      next[i] = change(next[i]);
    }
    return _withModules(next);
  }

  /// [m] into the panel [side] (or off). It keeps its place in the order,
  /// so it lands among that panel's modules where it stood before.
  KioskPanels withSide(KioskModule m, PanelSide side) =>
      _change(m, (p) => p._with(side: side));

  /// [m]'s share, held to 5–95.
  KioskPanels withShare(KioskModule m, int share) => _change(
    m,
    (p) => p._with(
      share: _clampInt(share, kioskModuleMinShare, kioskModuleMaxShare),
    ),
  );

  /// [m] [by] places up (negative) or down among the modules of its own
  /// panel, stopping at the first and the last; the modules elsewhere —
  /// in the other panel, off, unknown — keep their places. A module off
  /// does not move.
  KioskPanels moved(KioskModule m, int by) {
    final side = sideOf(m);
    if (side == PanelSide.off || by == 0) return this;
    final slots = [
      for (var i = 0; i < modules.length; i++)
        if (modules[i].module != null && modules[i].side == side) i,
    ];
    final from = slots.indexWhere((i) => modules[i].id == m.name);
    if (from < 0) return this;
    final to = _clampInt(from + by, 0, slots.length - 1);
    if (to == from) return this;
    final peers = [for (final i in slots) modules[i]];
    peers.insert(to, peers.removeAt(from));
    final next = [...modules];
    for (var k = 0; k < slots.length; k++) {
      next[slots[k]] = peers[k];
    }
    return _withModules(next);
  }

  /// The panel [side] with [days] (held to 1–13) and/or [open] changed.
  KioskPanels withPanel(PanelSide side, {int? days, bool? open}) {
    final old = panel(side);
    final next = KioskPanel(
      days: days == null
          ? old.days
          : _clampInt(days, kioskPanelMinDays, kioskPanelMaxDays),
      open: open ?? old.open,
    );
    return side == PanelSide.left
        ? KioskPanels(left: next, right: right, modules: modules)
        : KioskPanels(left: left, right: next, modules: modules);
  }

  @override
  bool operator ==(Object other) {
    if (other is! KioskPanels ||
        other.left != left ||
        other.right != right ||
        other.modules.length != modules.length) {
      return false;
    }
    for (var i = 0; i < modules.length; i++) {
      if (other.modules[i] != modules[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(left, right, Object.hashAll(modules));

  @override
  String toString() => 'KioskPanels(left: $left, right: $right, $modules)';
}

/// How wide each panel is on a screen [screenWidth] wide, in whole day
/// columns of the board — which sizes [visibleDays] columns on the whole
/// screen after the hour ruler ([rulerWidth]), so open or closed the board
/// shows whole days only. [left] and [right] are the days the admin asked
/// for, null for a side with nothing to show: it takes nothing. A present
/// panel gets 1 to `visibleDays − 1` columns; with both present their sum
/// is held to `visibleDays − 1`, the left giving way first. When even one
/// day each does not fit ([kioskPanelsExclusive]) both get one, and only
/// one of them is open at a time.
({double left, double right}) kioskPanelWidths(
  double screenWidth, {
  required double rulerWidth,
  required int visibleDays,
  int? left,
  int? right,
}) {
  final days = visibleDays < 2 ? 2 : visibleDays;
  final column = (screenWidth - rulerWidth) / days;
  final most = days - 1;
  var l = left == null ? null : _clampInt(left, 1, most);
  var r = right == null ? null : _clampInt(right, 1, most);
  if (l != null && r != null && l + r > most) {
    if (most < 2) {
      l = 1;
      r = 1;
    } else {
      l = most - r < 1 ? 1 : most - r;
      if (l + r > most) r = most - l;
    }
  }
  return (left: (l ?? 0) * column, right: (r ?? 0) * column);
}

/// Whether the two panels cannot be open at once: both have something to
/// show and the board has too few days for one column each beside a day of
/// its own (2 days on the screen) — opening one then closes the other.
bool kioskPanelsExclusive({
  required int visibleDays,
  required bool hasLeft,
  required bool hasRight,
}) =>
    hasLeft && hasRight && (visibleDays < 2 ? 2 : visibleDays) - 1 < 2;

/// 0077's conversion of the old single drawer's columns, in Dart: the
/// migration does this in SQL, and this mirror keeps its arithmetic under
/// unit tests with the tenancy suite's cases. The drawer becomes the right
/// panel (its columns and its resting state), the left one two closed
/// days; duty, notices and matches go right in the old fixed order when the
/// drawer was on and each was in it — the matches also with the list off
/// while live mode was on, as the match being played took the drawer then
/// — guide and week stay off. The shares come from the old nested weights
/// (duty [dutyShare] % of the drawer, notices [noticesShare] % of the
/// rest), rounded half away from zero like numeric `round()`: all three →
/// duty d, notices round((100 − d) · n / 100), matches the rest to 100;
/// duty with one other → d and 100 − d; no duty → notices n, matches
/// 100 − n; a module alone fills its panel whatever its share (duty d,
/// notices n, matches 100 − n, by the same rules). Each share is then held
/// to 5–95 — the matches' rest is counted from the notices before that. A
/// module off keeps its default share.
KioskPanels kioskPanelsFromLegacy({
  required bool panelEnabled,
  required bool drawerOpen,
  required int drawerColumns,
  required String noticesMode,
  required int noticesShare,
  required bool showMatches,
  required bool liveMode,
  required bool dutyDrawer,
  required int dutyShare,
}) {
  final duty = panelEnabled && dutyDrawer;
  final notices =
      panelEnabled && (noticesMode == 'drawer' || noticesMode == 'both');
  final matches = panelEnabled && (showMatches || liveMode);
  final d = dutyShare;
  final n = noticesShare;
  // The notices' part of what the duty leaves — 4.5 is 5, as in numeric.
  final noticesOfRest = ((100 - d) * n / 100).round();
  KioskModulePlacement place(KioskModule m, bool placed, int share) =>
      KioskModulePlacement(
        id: m.name,
        side: placed ? PanelSide.right : PanelSide.off,
        share: placed
            ? _clampInt(share, kioskModuleMinShare, kioskModuleMaxShare)
            : kioskModuleDefaultShare(m),
      );
  return KioskPanels(
    left: const KioskPanel(days: 2, open: false),
    right: KioskPanel(days: drawerColumns, open: drawerOpen),
    modules: List.unmodifiable([
      place(KioskModule.duty, duty, d),
      place(
        KioskModule.notices,
        notices,
        duty ? (matches ? noticesOfRest : 100 - d) : n,
      ),
      place(
        KioskModule.matches,
        matches,
        duty ? (notices ? 100 - d - noticesOfRest : 100 - d) : 100 - n,
      ),
      place(KioskModule.guide, false, 0),
      place(KioskModule.week, false, 0),
    ]),
  );
}
