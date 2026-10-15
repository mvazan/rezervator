import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/kiosk_layout.dart';

void main() {
  /// Every module as `id:side:share`, in the enum's order — one readable
  /// line per layout.
  String placed(KioskPanels p) => [
    for (final m in KioskModule.values)
      '${m.name}:${p.sideOf(m).name}:${p.shareOf(m)}',
  ].join(' ');

  /// The modules of [side] as `id:share`, in their order.
  String on(KioskPanels p, PanelSide side) =>
      [for (final m in p.modulesOn(side)) '${m.id}:${m.share}'].join(' ');

  group('the ids', () {
    test('the enum names are the JSON ids and sides', () {
      expect([for (final m in KioskModule.values) m.name], [
        'duty',
        'notices',
        'matches',
        'guide',
        'week',
      ]);
      expect([for (final s in PanelSide.values) s.name], [
        'off',
        'left',
        'right',
      ]);
    });

    test('every module has its default share', () {
      expect(
        [for (final m in KioskModule.values) kioskModuleDefaultShare(m)],
        [30, 40, 60, 45, 55],
      );
    });
  });

  group('KioskPanels.defaults', () {
    test('is the spec\'s default layout', () {
      expect(KioskPanels.defaults.toJson(), {
        'left': {'days': 2, 'open': false},
        'right': {'days': 2, 'open': false},
        'modules': [
          {'id': 'duty', 'side': 'off', 'share': 30},
          {'id': 'notices', 'side': 'right', 'share': 40},
          {'id': 'matches', 'side': 'right', 'share': 60},
          {'id': 'guide', 'side': 'off', 'share': 45},
          {'id': 'week', 'side': 'off', 'share': 55},
        ],
      });
      expect(on(KioskPanels.defaults, PanelSide.right), 'notices:40 matches:60');
      expect(on(KioskPanels.defaults, PanelSide.left), '');
    });
  });

  group('KioskPanels.fromJson', () {
    const full = {
      'left': {'days': 3, 'open': true},
      'right': {'days': 1, 'open': false},
      'modules': [
        {'id': 'guide', 'side': 'left', 'share': 45},
        {'id': 'week', 'side': 'left', 'share': 55},
        {'id': 'duty', 'side': 'right', 'share': 30},
        {'id': 'notices', 'side': 'right', 'share': 25},
        {'id': 'matches', 'side': 'off', 'share': 60},
      ],
    };

    test('reads a whole layout and writes it back the same', () {
      final p = KioskPanels.fromJson(full);
      expect(p.left, const KioskPanel(days: 3, open: true));
      expect(p.right, const KioskPanel(days: 1, open: false));
      expect(on(p, PanelSide.left), 'guide:45 week:55');
      expect(on(p, PanelSide.right), 'duty:30 notices:25');
      expect(p.sideOf(KioskModule.matches), PanelSide.off);
      expect(p.toJson(), full);
      // Through a JSON string and back, as the row travels.
      expect(KioskPanels.fromJson(jsonDecode(jsonEncode(p.toJson()))), p);
    });

    test('nothing usable reads as the defaults', () {
      for (final json in <Object?>[null, 'x', 3, const <String, Object?>{}]) {
        expect(KioskPanels.fromJson(json), KioskPanels.defaults,
            reason: '$json');
      }
      // A row from before 0077: no modules list → the default modules,
      // the panels as far as they are there.
      final p = KioskPanels.fromJson({
        'right': {'days': 4, 'open': true},
        'modules': {'id': 'duty'},
      });
      expect(p.right, const KioskPanel(days: 4, open: true));
      expect(p.left, const KioskPanel(days: 2, open: false));
      expect(p.modules, KioskPanels.defaults.modules);
    });

    test('a module the list lacks is added at its end, off, with its '
        'default share', () {
      final p = KioskPanels.fromJson({
        'left': {'days': 2, 'open': false},
        'right': {'days': 2, 'open': false},
        'modules': [
          {'id': 'matches', 'side': 'right', 'share': 70},
        ],
      });
      expect(p.toJson()['modules'], [
        {'id': 'matches', 'side': 'right', 'share': 70},
        {'id': 'duty', 'side': 'off', 'share': 30},
        {'id': 'notices', 'side': 'off', 'share': 40},
        {'id': 'guide', 'side': 'off', 'share': 45},
        {'id': 'week', 'side': 'off', 'share': 55},
      ]);
      // An empty list: every module off.
      final none = KioskPanels.fromJson({'modules': <Object?>[]});
      expect(on(none, PanelSide.left), '');
      expect(on(none, PanelSide.right), '');
      expect(none.modules, hasLength(5));
    });

    test('an id this build does not know is kept and written back '
        'unchanged — and left out of the panels', () {
      const radar = {
        'id': 'radar',
        'side': 'left',
        'share': 20,
        'colour': 'red',
      };
      final p = KioskPanels.fromJson({
        'left': {'days': 2, 'open': false},
        'right': {'days': 2, 'open': false},
        'modules': [
          {'id': 'guide', 'side': 'left', 'share': 45},
          radar,
          {'id': 'week', 'side': 'left', 'share': 55},
        ],
      });
      final unknown = p.modules[1];
      expect(unknown.id, 'radar');
      expect(unknown.module, isNull);
      expect(unknown.raw, radar);
      expect(on(p, PanelSide.left), 'guide:45 week:55');
      expect((p.toJson()['modules'] as List)[1], radar);
      // The admin's edits keep it where it was, as it was.
      final edited = p
          .withSide(KioskModule.duty, PanelSide.left)
          .withShare(KioskModule.guide, 60)
          .moved(KioskModule.week, -1)
          .withPanel(PanelSide.left, days: 3);
      expect(edited.modules[1].id, 'radar');
      expect((edited.toJson()['modules'] as List)[1], radar);
      expect(on(edited, PanelSide.left), 'week:55 guide:60 duty:30');
    });

    test('an id\'s second entry, an entry without an id and one that is no '
        'object are skipped', () {
      final p = KioskPanels.fromJson({
        'modules': [
          {'id': 'notices', 'side': 'left', 'share': 30},
          {'id': 'notices', 'side': 'right', 'share': 70},
          {'side': 'right', 'share': 50},
          {'id': '', 'side': 'right', 'share': 50},
          {'id': 7, 'side': 'right', 'share': 50},
          'matches',
          null,
        ],
      });
      expect(p.sideOf(KioskModule.notices), PanelSide.left);
      expect(p.shareOf(KioskModule.notices), 30);
      expect(p.modules.where((m) => m.id == 'notices'), hasLength(1));
      expect(p.modules, hasLength(5));
      expect(p.sideOf(KioskModule.matches), PanelSide.off);
    });

    test('a bad value falls back on its own', () {
      Map<String, Object?> layout(Object? days, Object? open, Object? side,
              Object? share) =>
          {
            'left': {'days': days, 'open': open},
            'right': {'days': 5, 'open': true},
            'modules': [
              {'id': 'week', 'side': side, 'share': share},
            ],
          };
      for (final (days, read) in <(Object?, int)>[
        (0, 2),
        (14, 2),
        (2.5, 2),
        ('3', 2),
        (null, 2),
        (1, 1),
        (13, 13),
        // A whole JSON number written as 3.0 is 3 (as the check sees it).
        (3.0, 3),
      ]) {
        expect(
          KioskPanels.fromJson(layout(days, false, 'left', 50)).left.days,
          read,
          reason: 'days $days',
        );
      }
      expect(KioskPanels.fromJson(layout(2, 'true', 'left', 50)).left.open,
          isFalse);
      expect(KioskPanels.fromJson(layout(2, true, 'left', 50)).left.open,
          isTrue);
      expect(
        KioskPanels.fromJson(layout(2, false, 'top', 50))
            .sideOf(KioskModule.week),
        PanelSide.off,
      );
      expect(
        KioskPanels.fromJson(layout(2, false, null, 50))
            .sideOf(KioskModule.week),
        PanelSide.off,
      );
      for (final (share, read) in <(Object?, int)>[
        (4, 55),
        (96, 55),
        ('50', 55),
        (50.5, 55),
        (null, 55),
        (5, 5),
        (95, 95),
      ]) {
        expect(
          KioskPanels.fromJson(layout(2, false, 'left', share))
              .shareOf(KioskModule.week),
          read,
          reason: 'share $share',
        );
      }
      // The right panel is untouched by the left's bad values.
      expect(KioskPanels.fromJson(layout(0, 'x', 'top', 4)).right,
          const KioskPanel(days: 5, open: true));
    });
  });

  group('reading the layout', () {
    test('panel() of off is an error', () {
      expect(KioskPanels.defaults.panel(PanelSide.left),
          const KioskPanel(days: 2, open: false));
      expect(() => KioskPanels.defaults.panel(PanelSide.off),
          throwsArgumentError);
    });

    test('sideOf and shareOf of a module a hand-built layout lacks: off, '
        'its default share', () {
      const bare = KioskPanels(
        left: KioskPanel(days: 2, open: false),
        right: KioskPanel(days: 2, open: false),
        modules: [],
      );
      expect(bare.sideOf(KioskModule.week), PanelSide.off);
      expect(bare.shareOf(KioskModule.week), 55);
      expect(
        on(bare.withSide(KioskModule.week, PanelSide.left), PanelSide.left),
        'week:55',
      );
    });
  });

  group('the admin\'s edits', () {
    test('withSide keeps the module\'s place in the order', () {
      final p = KioskPanels.defaults.withSide(KioskModule.duty, PanelSide.right);
      // Duty stood first, so it comes first in the right panel.
      expect(on(p, PanelSide.right), 'duty:30 notices:40 matches:60');
      final q = p
          .withSide(KioskModule.notices, PanelSide.left)
          .withSide(KioskModule.guide, PanelSide.left);
      expect(on(q, PanelSide.left), 'notices:40 guide:45');
      expect(on(q, PanelSide.right), 'duty:30 matches:60');
      expect(q.withSide(KioskModule.duty, PanelSide.off).sideOf(KioskModule.duty),
          PanelSide.off);
      // The original is untouched.
      expect(KioskPanels.defaults.sideOf(KioskModule.duty), PanelSide.off);
    });

    test('withShare holds the share to 5–95', () {
      final p = KioskPanels.defaults;
      expect(p.withShare(KioskModule.notices, 25).shareOf(KioskModule.notices),
          25);
      expect(p.withShare(KioskModule.notices, 2).shareOf(KioskModule.notices),
          5);
      expect(p.withShare(KioskModule.notices, 120).shareOf(KioskModule.notices),
          95);
    });

    test('moved steps among the modules of its own panel only', () {
      final p = KioskPanels.fromJson({
        'modules': [
          {'id': 'duty', 'side': 'right', 'share': 30},
          {'id': 'guide', 'side': 'left', 'share': 45},
          {'id': 'notices', 'side': 'right', 'share': 40},
          {'id': 'week', 'side': 'off', 'share': 55},
          {'id': 'matches', 'side': 'right', 'share': 60},
        ],
      });
      expect(on(p.moved(KioskModule.matches, -1), PanelSide.right),
          'duty:30 matches:60 notices:40');
      expect(on(p.moved(KioskModule.matches, -2), PanelSide.right),
          'matches:60 duty:30 notices:40');
      expect(on(p.moved(KioskModule.duty, 1), PanelSide.right),
          'notices:40 duty:30 matches:60');
      // Past the ends it stops there.
      expect(p.moved(KioskModule.duty, -1), p);
      expect(on(p.moved(KioskModule.duty, 9), PanelSide.right),
          'notices:40 matches:60 duty:30');
      // The left panel's guide and the week off keep their places.
      final moved = p.moved(KioskModule.matches, -2);
      expect([for (final m in moved.modules) m.id],
          ['matches', 'guide', 'duty', 'week', 'notices']);
      // Alone in its panel, or off: nothing moves.
      expect(p.moved(KioskModule.guide, 1), p);
      expect(p.moved(KioskModule.week, -1), p);
      expect(p.moved(KioskModule.notices, 0), p);
    });

    test('withPanel changes the days (held to 1–13) and the resting state of '
        'one panel', () {
      final p = KioskPanels.defaults
          .withPanel(PanelSide.left, days: 4)
          .withPanel(PanelSide.right, open: true);
      expect(p.left, const KioskPanel(days: 4, open: false));
      expect(p.right, const KioskPanel(days: 2, open: true));
      expect(p.withPanel(PanelSide.left, days: 0).left.days, 1);
      expect(p.withPanel(PanelSide.left, days: 20).left.days, 13);
      expect(p.modules, KioskPanels.defaults.modules);
      expect(() => p.withPanel(PanelSide.off, days: 2), throwsArgumentError);
    });

    test('every edit PATCHes as a whole layout the check accepts', () {
      final p = KioskPanels.defaults
          .withSide(KioskModule.guide, PanelSide.left)
          .withSide(KioskModule.week, PanelSide.left)
          .withShare(KioskModule.week, 70)
          .moved(KioskModule.week, -1)
          .withPanel(PanelSide.left, days: 3, open: true);
      expect(p.toJson(), {
        'left': {'days': 3, 'open': true},
        'right': {'days': 2, 'open': false},
        'modules': [
          {'id': 'duty', 'side': 'off', 'share': 30},
          {'id': 'notices', 'side': 'right', 'share': 40},
          {'id': 'matches', 'side': 'right', 'share': 60},
          {'id': 'week', 'side': 'left', 'share': 70},
          {'id': 'guide', 'side': 'left', 'share': 45},
        ],
      });
      expect(KioskPanels.fromJson(p.toJson()), p);
    });
  });

  group('kioskPanelWidths', () {
    // 1920 px, the 46 px hour ruler, 7 days: a day column is 1874 / 7.
    const col7 = (1920 - 46) / 7;
    ({double left, double right}) widths({
      int visibleDays = 7,
      int? left,
      int? right,
    }) => kioskPanelWidths(
      1920,
      rulerWidth: 46,
      visibleDays: visibleDays,
      left: left,
      right: right,
    );

    test('a side with nothing to show takes nothing', () {
      expect(widths(), (left: 0.0, right: 0.0));
      expect(widths(left: 2), (left: 2 * col7, right: 0.0));
      expect(widths(right: 3), (left: 0.0, right: 3 * col7));
      // A converted drawer of 6 of 7 days keeps its 6 beside an empty left.
      expect(widths(right: 6), (left: 0.0, right: 6 * col7));
    });

    test('one panel gets 1 to visibleDays − 1 columns', () {
      expect(widths(right: 0), (left: 0.0, right: 1 * col7));
      expect(widths(right: 13), (left: 0.0, right: 6 * col7));
      expect(widths(left: -2), (left: 1 * col7, right: 0.0));
    });

    test('both together get at most visibleDays − 1, the left giving way '
        'first', () {
      expect(widths(left: 2, right: 2), (left: 2 * col7, right: 2 * col7));
      expect(widths(left: 4, right: 4), (left: 2 * col7, right: 4 * col7));
      expect(widths(left: 3, right: 6), (left: 1 * col7, right: 5 * col7));
      expect(widths(left: 13, right: 13), (left: 1 * col7, right: 5 * col7));
      const col3 = (1920 - 46) / 3;
      expect(widths(visibleDays: 3, left: 2, right: 2),
          (left: 1 * col3, right: 1 * col3));
    });

    test('two days on the screen: one column each, and only one open', () {
      const col2 = (1920 - 46) / 2;
      expect(widths(visibleDays: 2, left: 3, right: 3),
          (left: 1 * col2, right: 1 * col2));
      expect(widths(visibleDays: 2, right: 3), (left: 0.0, right: 1 * col2));
      // Below the column's check (2–14) it reads as 2.
      expect(widths(visibleDays: 1, left: 1), (left: 1 * col2, right: 0.0));
      expect(
        kioskPanelsExclusive(visibleDays: 2, hasLeft: true, hasRight: true),
        isTrue,
      );
      expect(
        kioskPanelsExclusive(visibleDays: 3, hasLeft: true, hasRight: true),
        isFalse,
      );
      expect(
        kioskPanelsExclusive(visibleDays: 2, hasLeft: false, hasRight: true),
        isFalse,
      );
      expect(
        kioskPanelsExclusive(visibleDays: 1, hasLeft: true, hasRight: true),
        isTrue,
      );
    });
  });

  group('kioskPanelsFromLegacy (0077\'s conversion, mirrored)', () {
    KioskPanels legacy({
      bool panelEnabled = true,
      bool drawerOpen = false,
      int drawerColumns = 2,
      String noticesMode = 'both',
      int noticesShare = 40,
      bool showMatches = true,
      bool liveMode = true,
      bool dutyDrawer = false,
      int dutyShare = 30,
    }) => kioskPanelsFromLegacy(
      panelEnabled: panelEnabled,
      drawerOpen: drawerOpen,
      drawerColumns: drawerColumns,
      noticesMode: noticesMode,
      noticesShare: noticesShare,
      showMatches: showMatches,
      liveMode: liveMode,
      dutyDrawer: dutyDrawer,
      dutyShare: dutyShare,
    );

    test('the old defaults become the new defaults', () {
      expect(legacy(), KioskPanels.defaults);
    });

    test('the drawer becomes the right panel; the left is two closed days',
        () {
      final p = legacy(drawerColumns: 5, drawerOpen: true);
      expect(p.right, const KioskPanel(days: 5, open: true));
      expect(p.left, const KioskPanel(days: 2, open: false));
      // Off, the panel keeps its geometry — and nothing goes into it.
      final off = legacy(
        panelEnabled: false,
        drawerColumns: 3,
        drawerOpen: true,
        dutyDrawer: true,
      );
      expect(off.right, const KioskPanel(days: 3, open: true));
      expect(placed(off),
          'duty:off:30 notices:off:40 matches:off:60 guide:off:45 week:off:55');
    });

    test('duty, notices and matches: d, round((100 − d) · n / 100), the rest '
        '— each held to 5–95', () {
      for (final (d, n, shares) in [
        (30, 40, 'duty:right:30 notices:right:28 matches:right:42'),
        // 1 → 5; the rest is counted from the 1: 100 − 90 − 1.
        (90, 10, 'duty:right:90 notices:right:5 matches:right:9'),
        (90, 90, 'duty:right:90 notices:right:9 matches:right:5'),
        (60, 10, 'duty:right:60 notices:right:5 matches:right:36'),
        // 4.5 rounds half away from zero to 5 (numeric, not float8's 4).
        (55, 10, 'duty:right:55 notices:right:5 matches:right:40'),
      ]) {
        expect(
          placed(legacy(dutyDrawer: true, dutyShare: d, noticesShare: n)),
          '$shares guide:off:45 week:off:55',
          reason: '($d, $n)',
        );
      }
      // In the old fixed order: duty on top.
      expect(
        on(legacy(dutyDrawer: true), PanelSide.right),
        'duty:30 notices:28 matches:42',
      );
    });

    test('duty with one other: d and 100 − d', () {
      // Only the matches: notices in the header alone.
      expect(
        placed(legacy(dutyDrawer: true, noticesMode: 'header')),
        'duty:right:30 notices:off:40 matches:right:70 guide:off:45 '
        'week:off:55',
      );
      // Only the notices: no list and no live mode.
      expect(
        placed(legacy(
          dutyDrawer: true,
          dutyShare: 60,
          showMatches: false,
          liveMode: false,
        )),
        'duty:right:60 notices:right:40 matches:off:60 guide:off:45 '
        'week:off:55',
      );
    });

    test('no duty: notices n, matches 100 − n', () {
      expect(
        placed(legacy(noticesShare: 25)),
        'duty:off:30 notices:right:25 matches:right:75 guide:off:45 '
        'week:off:55',
      );
      expect(
        placed(legacy(noticesMode: 'drawer', noticesShare: 90)),
        'duty:off:30 notices:right:90 matches:right:10 guide:off:45 '
        'week:off:55',
      );
    });

    test('the list off with live mode on keeps the matches (the match being '
        'played took the drawer); with live mode off they go', () {
      expect(
        placed(legacy(showMatches: false, liveMode: true)),
        'duty:off:30 notices:right:40 matches:right:60 guide:off:45 '
        'week:off:55',
      );
      expect(
        legacy(showMatches: false, liveMode: false)
            .sideOf(KioskModule.matches),
        PanelSide.off,
      );
    });

    test('the notices go right only from drawer or both', () {
      for (final (mode, side) in [
        ('off', PanelSide.off),
        ('header', PanelSide.off),
        ('drawer', PanelSide.right),
        ('both', PanelSide.right),
      ]) {
        expect(legacy(noticesMode: mode).sideOf(KioskModule.notices), side,
            reason: mode);
      }
    });

    test('a module alone fills its panel; its share follows the same rules',
        () {
      expect(
        placed(legacy(
          dutyDrawer: true,
          dutyShare: 70,
          noticesMode: 'header',
          showMatches: false,
          liveMode: false,
        )),
        'duty:right:70 notices:off:40 matches:off:60 guide:off:45 '
        'week:off:55',
      );
      expect(
        placed(legacy(noticesMode: 'off', noticesShare: 30)),
        'duty:off:30 notices:off:40 matches:right:70 guide:off:45 '
        'week:off:55',
      );
      expect(
        placed(legacy(showMatches: false, liveMode: false, noticesShare: 30)),
        'duty:off:30 notices:right:30 matches:off:60 guide:off:45 '
        'week:off:55',
      );
    });
  });
}
