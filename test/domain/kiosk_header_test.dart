import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/kiosk_header.dart';
import 'package:rezervator/domain/kiosk_layout.dart';

void main() {
  /// Every entry as `id:side`, in the list's order — one readable line per
  /// layout.
  String placed(KioskHeader h) =>
      [for (final m in h.modules) '${m.id}:${m.side.name}'].join(' ');

  /// The known modules of [side] as ids, in their order.
  String on(KioskHeader h, PanelSide side) =>
      [for (final m in h.modulesOn(side)) m.id].join(' ');

  /// What 0082's `kiosk_header_valid` asks of a layout: an object whose
  /// `modules` is a list of objects, each with a non-empty string id (no
  /// two alike) and a side off, left or right.
  bool valid(Object? json) {
    if (json is! Map<String, Object?>) return false;
    final list = json['modules'];
    if (list is! List) return false;
    final ids = <String>{};
    for (final entry in list) {
      if (entry is! Map<String, Object?>) return false;
      final id = entry['id'];
      final side = entry['side'];
      if (id is! String || id.isEmpty || !ids.add(id)) return false;
      if (side is! String || !const {'off', 'left', 'right'}.contains(side)) {
        return false;
      }
    }
    return true;
  }

  group('the ids', () {
    test('the enum names are the JSON ids', () {
      expect([for (final m in KioskHeaderModule.values) m.name], [
        'weather',
        'nameday',
        'duty',
        'notices',
      ]);
    });

    test('the weather\'s default title', () {
      expect(kioskWeatherDefaultTitle, 'Počasí');
    });
  });

  group('KioskHeader.defaults', () {
    test('is the spec\'s default layout', () {
      expect(KioskHeader.defaults.toJson(), {
        'modules': [
          {'id': 'weather', 'side': 'off'},
          {'id': 'nameday', 'side': 'off'},
          {'id': 'duty', 'side': 'off'},
          {'id': 'notices', 'side': 'right'},
        ],
      });
      expect(on(KioskHeader.defaults, PanelSide.right), 'notices');
      expect(on(KioskHeader.defaults, PanelSide.left), '');
    });

    test('is 0082\'s column default, value for value', () {
      // Every alley without a saved layout gets 0082's default; the app's
      // fallback must be the same layout.
      final sql = File(
        'supabase/migrations/0082_kiosk_header.sql',
      ).readAsStringSync();
      final column = RegExp(
        r"kiosk_header\s+jsonb[^;']*?default\s+'(\{[^']*\})'",
      ).firstMatch(sql)!.group(1)!;
      final decoded = jsonDecode(column);
      expect(decoded, KioskHeader.defaults.toJson());
      expect(KioskHeader.fromJson(decoded), KioskHeader.defaults);
    });
  });

  group('KioskHeader.fromJson', () {
    const full = {
      'modules': [
        {'id': 'duty', 'side': 'left'},
        {'id': 'weather', 'side': 'left'},
        {'id': 'notices', 'side': 'right'},
        {'id': 'nameday', 'side': 'off'},
      ],
    };

    test('reads a whole layout and writes it back the same', () {
      final h = KioskHeader.fromJson(full);
      expect(placed(h), 'duty:left weather:left notices:right nameday:off');
      expect(on(h, PanelSide.left), 'duty weather');
      expect(on(h, PanelSide.right), 'notices');
      expect(h.toJson(), full);
      // Through a JSON string and back, as the row travels.
      expect(KioskHeader.fromJson(jsonDecode(jsonEncode(h.toJson()))), h);
    });

    test('nothing usable reads as the defaults', () {
      for (final json in <Object?>[
        null,
        'x',
        3,
        const <String, Object?>{},
        const {'modules': 3},
        const {
          'modules': {'id': 'weather', 'side': 'left'},
        },
      ]) {
        expect(KioskHeader.fromJson(json), KioskHeader.defaults,
            reason: '$json');
      }
    });

    test('a module the list lacks is added at its end, off, in the enum\'s '
        'order', () {
      final h = KioskHeader.fromJson({
        'modules': [
          {'id': 'notices', 'side': 'left'},
          {'id': 'nameday', 'side': 'right'},
        ],
      });
      expect(placed(h), 'notices:left nameday:right weather:off duty:off');
      // An empty list: every module off — the notices too.
      final none = KioskHeader.fromJson({'modules': <Object?>[]});
      expect(placed(none), 'weather:off nameday:off duty:off notices:off');
      expect(on(none, PanelSide.left), '');
      expect(on(none, PanelSide.right), '');
    });

    test('an id this build does not know is kept and written back '
        'unchanged — and left out of the sides', () {
      const later = {'id': 'later', 'side': 'left', 'x': 1};
      final h = KioskHeader.fromJson({
        'modules': [
          {'id': 'weather', 'side': 'left'},
          later,
          {'id': 'nameday', 'side': 'left'},
        ],
      });
      final unknown = h.modules[1];
      expect(unknown.id, 'later');
      expect(unknown.module, isNull);
      expect(unknown.side, PanelSide.left);
      expect(unknown.raw, later);
      expect(on(h, PanelSide.left), 'weather nameday');
      expect((h.toJson()['modules'] as List)[1], later);
      // The admin's edits keep it where it was, as it was.
      final edited = h
          .withSide(KioskHeaderModule.duty, PanelSide.left)
          .moved(KioskHeaderModule.nameday, -1);
      expect(edited.modules[1].id, 'later');
      expect((edited.toJson()['modules'] as List)[1], later);
      expect(on(edited, PanelSide.left), 'nameday weather duty');
    });

    test('an id\'s second entry, an entry without an id, an empty id and '
        'one that is no object are skipped', () {
      final h = KioskHeader.fromJson({
        'modules': [
          {'id': 'notices', 'side': 'left'},
          {'id': 'notices', 'side': 'right'},
          {'side': 'right'},
          {'id': '', 'side': 'right'},
          {'id': 7, 'side': 'right'},
          'weather',
          null,
          3,
        ],
      });
      expect(h.sideOf(KioskHeaderModule.notices), PanelSide.left);
      expect(h.modules.where((m) => m.id == 'notices'), hasLength(1));
      expect(h.modules, hasLength(4));
      expect(placed(h), 'notices:left weather:off nameday:off duty:off');
    });

    test('an unknown or missing side reads as off', () {
      for (final side in <Object?>['middle', 'LEFT', null, 1, true]) {
        final h = KioskHeader.fromJson({
          'modules': [
            {'id': 'weather', 'side': side},
          ],
        });
        expect(h.sideOf(KioskHeaderModule.weather), PanelSide.off,
            reason: '$side');
      }
    });
  });

  group('reading the layout', () {
    final h = KioskHeader.fromJson({
      'modules': [
        {'id': 'nameday', 'side': 'right'},
        {'id': 'weather', 'side': 'left'},
        {'id': 'later', 'side': 'left'},
        {'id': 'duty', 'side': 'left'},
        {'id': 'notices', 'side': 'off'},
      ],
    });

    test('modulesOn lists only the known modules of a side, in order', () {
      expect(on(h, PanelSide.left), 'weather duty');
      expect(on(h, PanelSide.right), 'nameday');
      expect(on(h, PanelSide.off), 'notices');
      expect(
        [for (final p in h.modulesOn(PanelSide.left)) p.module],
        [KioskHeaderModule.weather, KioskHeaderModule.duty],
      );
    });

    test('sideOf and isOn', () {
      expect(h.sideOf(KioskHeaderModule.weather), PanelSide.left);
      expect(h.sideOf(KioskHeaderModule.nameday), PanelSide.right);
      expect(h.sideOf(KioskHeaderModule.notices), PanelSide.off);
      expect(h.isOn(KioskHeaderModule.weather), isTrue);
      expect(h.isOn(KioskHeaderModule.nameday), isTrue);
      expect(h.isOn(KioskHeaderModule.notices), isFalse);
      expect(KioskHeader.defaults.isOn(KioskHeaderModule.notices), isTrue);
      expect(KioskHeader.defaults.isOn(KioskHeaderModule.duty), isFalse);
    });

    test('a module a hand-built layout lacks is off', () {
      const bare = KioskHeader(modules: []);
      expect(bare.sideOf(KioskHeaderModule.duty), PanelSide.off);
      expect(bare.isOn(KioskHeaderModule.duty), isFalse);
      expect(
        on(bare.withSide(KioskHeaderModule.duty, PanelSide.left),
            PanelSide.left),
        'duty',
      );
    });
  });

  group('the admin\'s edits', () {
    test('withSide keeps the module\'s place in the order', () {
      final h = KioskHeader.defaults
          .withSide(KioskHeaderModule.duty, PanelSide.right);
      // The duty stood before the notices, so it comes first on the right.
      expect(on(h, PanelSide.right), 'duty notices');
      final g = h
          .withSide(KioskHeaderModule.nameday, PanelSide.left)
          .withSide(KioskHeaderModule.weather, PanelSide.left);
      expect(on(g, PanelSide.left), 'weather nameday');
      expect(placed(g), 'weather:left nameday:left duty:right notices:right');
      expect(
        g.withSide(KioskHeaderModule.duty, PanelSide.off)
            .sideOf(KioskHeaderModule.duty),
        PanelSide.off,
      );
      // The original is untouched.
      expect(KioskHeader.defaults.sideOf(KioskHeaderModule.duty),
          PanelSide.off);
    });

    test('moved steps among the known modules of its own side only', () {
      final h = KioskHeader.fromJson({
        'modules': [
          {'id': 'weather', 'side': 'left'},
          {'id': 'notices', 'side': 'right'},
          {'id': 'later', 'side': 'left'},
          {'id': 'nameday', 'side': 'left'},
          {'id': 'duty', 'side': 'left'},
        ],
      });
      expect(on(h.moved(KioskHeaderModule.duty, -1), PanelSide.left),
          'weather duty nameday');
      expect(on(h.moved(KioskHeaderModule.duty, -2), PanelSide.left),
          'duty weather nameday');
      expect(on(h.moved(KioskHeaderModule.weather, 1), PanelSide.left),
          'nameday weather duty');
      // Past the ends it stops there.
      expect(h.moved(KioskHeaderModule.weather, -1), h);
      expect(h.moved(KioskHeaderModule.duty, 1), h);
      expect(on(h.moved(KioskHeaderModule.weather, 9), PanelSide.left),
          'nameday duty weather');
      // The right side's notices and the unknown entry keep their places.
      final moved = h.moved(KioskHeaderModule.duty, -2);
      expect([for (final m in moved.modules) m.id],
          ['duty', 'notices', 'later', 'weather', 'nameday']);
      // Alone on its side, or off: nothing moves.
      expect(h.moved(KioskHeaderModule.notices, 1), h);
      expect(h.moved(KioskHeaderModule.notices, -1), h);
      expect(
        KioskHeader.defaults.moved(KioskHeaderModule.weather, 1),
        KioskHeader.defaults,
      );
      expect(h.moved(KioskHeaderModule.nameday, 0), h);
    });

    test('every edit PATCHes as a whole layout the check accepts', () {
      final h = KioskHeader.defaults
          .withSide(KioskHeaderModule.weather, PanelSide.left)
          .withSide(KioskHeaderModule.nameday, PanelSide.left)
          .withSide(KioskHeaderModule.duty, PanelSide.right)
          .moved(KioskHeaderModule.nameday, -1)
          .moved(KioskHeaderModule.notices, -1);
      expect(h.toJson(), {
        'modules': [
          {'id': 'nameday', 'side': 'left'},
          {'id': 'weather', 'side': 'left'},
          {'id': 'notices', 'side': 'right'},
          {'id': 'duty', 'side': 'right'},
        ],
      });
      expect(valid(h.toJson()), isTrue);
      expect(KioskHeader.fromJson(h.toJson()), h);
    });
  });

  group('equality', () {
    test('equal layouts are equal and hash alike', () {
      final a = KioskHeader.fromJson(KioskHeader.defaults.toJson());
      expect(a, KioskHeader.defaults);
      expect(a.hashCode, KioskHeader.defaults.hashCode);
      final b = a.withSide(KioskHeaderModule.weather, PanelSide.left);
      final c = KioskHeader.defaults
          .withSide(KioskHeaderModule.weather, PanelSide.left);
      expect(b, c);
      expect(b.hashCode, c.hashCode);
    });

    test('a different side, order or unknown entry is a different layout',
        () {
      final a = KioskHeader.defaults;
      expect(a.withSide(KioskHeaderModule.weather, PanelSide.left), isNot(a));
      final both = a
          .withSide(KioskHeaderModule.weather, PanelSide.left)
          .withSide(KioskHeaderModule.nameday, PanelSide.left);
      expect(both.moved(KioskHeaderModule.nameday, -1), isNot(both));
      Map<String, Object?> later(Object? x) => {
        'modules': [
          {'id': 'later', 'side': 'left', 'x': x},
        ],
      };
      expect(KioskHeader.fromJson(later(1)), isNot(KioskHeader.fromJson(
          later(2))));
      expect(KioskHeader.fromJson(later(1)), KioskHeader.fromJson(later(1)));
    });
  });

  group('kioskHeaderFromLegacy (0082\'s conversion)', () {
    String legacy({
      bool weather = false,
      bool nameday = false,
      bool dutyHeader = false,
      bool noticesHeader = false,
    }) => placed(
      kioskHeaderFromLegacy(
        weather: weather,
        nameday: nameday,
        dutyHeader: dutyHeader,
        noticesHeader: noticesHeader,
      ),
    );

    test('the tenancy suite\'s cases', () {
      // All off.
      expect(legacy(), 'weather:off nameday:off duty:off notices:off');
      // All on: the weather, the name day and the duty left, the notices
      // right, in that order.
      expect(
        legacy(
          weather: true,
          nameday: true,
          dutyHeader: true,
          noticesHeader: true,
        ),
        'weather:left nameday:left duty:left notices:right',
      );
      // Only the weather.
      expect(legacy(weather: true),
          'weather:left nameday:off duty:off notices:off');
      // Everything but the notices.
      expect(
        legacy(weather: true, nameday: true, dutyHeader: true),
        'weather:left nameday:left duty:left notices:off',
      );
      // The name day and the duty.
      expect(legacy(nameday: true, dutyHeader: true),
          'weather:off nameday:left duty:left notices:off');
    });

    test('the old switches\' defaults convert to the column default', () {
      // kiosk_weather, kiosk_nameday and kiosk_duty_header were off by
      // default, kiosk_notices_header on.
      expect(
        kioskHeaderFromLegacy(
          weather: false,
          nameday: false,
          dutyHeader: false,
          noticesHeader: true,
        ),
        KioskHeader.defaults,
      );
    });

    test('every conversion is a layout the check accepts', () {
      for (var bits = 0; bits < 16; bits++) {
        final h = kioskHeaderFromLegacy(
          weather: bits & 1 != 0,
          nameday: bits & 2 != 0,
          dutyHeader: bits & 4 != 0,
          noticesHeader: bits & 8 != 0,
        );
        expect(valid(h.toJson()), isTrue, reason: '$bits');
        expect(KioskHeader.fromJson(h.toJson()), h, reason: '$bits');
      }
    });
  });

  test('the weather\'s title on the kiosk: the place with a colon, like '
      'every module\'s; „Počasí:“ without one; no second colon', () {
    expect(kioskWeatherTitleOf('Brno'), 'Brno:');
    expect(kioskWeatherTitleOf('  Brno  '), 'Brno:');
    expect(kioskWeatherTitleOf('Brno:'), 'Brno:');
    expect(kioskWeatherTitleOf(null), 'Počasí:');
    expect(kioskWeatherTitleOf('   '), 'Počasí:');
  });
}
