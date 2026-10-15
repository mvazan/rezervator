import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/features/auth/update_screen.dart';
import 'package:rezervator/features/kiosk/kiosk_qr.dart';

/// The kiosk's Google Play QR code (kiosk_qr.dart): a bundled matrix — no
/// decoder runs here, so its structure is checked against the standard
/// (version 4: finder, timing and alignment patterns, the dark module) —
/// and the tile that draws it, whole device pixels a module.
void main() {
  const n = 33;
  bool dark(int r, int c) => kioskPlayQr[r][c] == '#';

  group('kioskPlayQr', () {
    test('leads to the app\'s Google Play page, as the update screen', () {
      expect(kioskPlayUrl, UpdateScreen.playUrl);
    });

    test('is a square of version 4: 33 rows of 33 modules, # or .', () {
      expect(kioskPlayQr, hasLength(4 * 4 + 17));
      for (final row in kioskPlayQr) {
        expect(row, hasLength(n));
        expect(RegExp(r'^[#.]+$').hasMatch(row), isTrue, reason: row);
      }
    });

    test('has the three 7 × 7 finder patterns, each with its light '
        'separator', () {
      for (final (top, left) in [(0, 0), (0, n - 7), (n - 7, 0)]) {
        for (var i = 0; i < 7; i++) {
          for (var j = 0; j < 7; j++) {
            final ring = i == 0 || i == 6 || j == 0 || j == 6;
            final core = i >= 2 && i <= 4 && j >= 2 && j <= 4;
            expect(
              dark(top + i, left + j),
              ring || core,
              reason: 'finder at ($top, $left), module ($i, $j)',
            );
          }
        }
        // The separator: the light row and column on its inner sides.
        final sepRow = top == 0 ? 7 : n - 8;
        final sepCol = left == 0 ? 7 : n - 8;
        for (var k = 0; k < 8; k++) {
          expect(dark(sepRow, left == 0 ? k : n - 8 + k), isFalse);
          expect(dark(top == 0 ? k : n - 8 + k, sepCol), isFalse);
        }
      }
    });

    test('has the timing row and column between the finders: dark and '
        'light in turn, dark on the even modules', () {
      for (var k = 8; k < n - 8; k++) {
        expect(dark(6, k), k.isEven, reason: 'timing row, column $k');
        expect(dark(k, 6), k.isEven, reason: 'timing column, row $k');
      }
    });

    test('has version 4\'s alignment pattern at (26, 26) and the dark '
        'module at (25, 8)', () {
      for (var i = -2; i <= 2; i++) {
        for (var j = -2; j <= 2; j++) {
          final ring = i.abs() == 2 || j.abs() == 2;
          expect(dark(26 + i, 26 + j), ring || (i == 0 && j == 0));
        }
      }
      expect(dark(4 * 4 + 9, 8), isTrue);
    });
  });

  group('kioskQrTile', () {
    test('whole device pixels a module, the quiet zone included: 41 '
        'modules', () {
      expect(kioskQrTile(220, 1, n), 205); // 5 px a module
      expect(kioskQrTile(300, 1, n), 287); // 7
      expect(kioskQrTile(123, 1, n), 123); // 3
      // 1.5 device pixels to one: 8 device pixels a module.
      expect(kioskQrTile(220, 1.5, n), closeTo(328 / 1.5, 1e-9));
      for (final dpr in [1.0, 1.5, 2.0, 2.625, 3.0]) {
        for (var size = 100.0; size <= 320; size += 7.3) {
          final tile = kioskQrTile(size, dpr, n);
          if (tile == 0) continue;
          final device = tile * dpr;
          expect(device, closeTo(device.roundToDouble(), 1e-6));
          expect(device.round() % 41, 0, reason: 'size $size at $dpr');
          expect(tile, lessThanOrEqualTo(size + 1e-9));
        }
      }
    });

    test('0 under 3 device pixels a module', () {
      expect(kioskQrTile(122, 1, n), 0); // 2 px a module
      expect(kioskQrTile(81.9, 1.5, n), 0); // 2.99… px
      expect(kioskQrTile(82, 1.5, n), 82); // 3 px: drawn
    });

    test('a size that is itself a tile keeps its modules', () {
      for (final dpr in [1.0, 1.5, 2.625, 3.0]) {
        for (var m = 3; m < 12; m++) {
          final tile = m * 41 / dpr;
          expect(kioskQrTile(tile, dpr, n), closeTo(tile, 1e-9));
        }
      }
    });
  });

  group('KioskQr', () {
    Future<RenderRepaintBoundary> pump(
      WidgetTester tester, {
      required double size,
      double dpr = 1,
    }) async {
      tester.view.physicalSize = const Size(800, 600) * dpr;
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: key,
              child: KioskQr(
                rows: kioskPlayQr,
                size: size,
                semanticLabel: kioskPlayQrLabel,
              ),
            ),
          ),
        ),
      );
      return tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
    }

    testWidgets('takes the tile of whole modules that fits its size', (
      tester,
    ) async {
      await pump(tester, size: 220);
      expect(tester.getSize(find.byType(KioskQr)), const Size(205, 205));
      await pump(tester, size: 220, dpr: 1.5);
      expect(
        tester.getSize(find.byType(KioskQr)).width,
        closeTo(328 / 1.5, 1e-9),
      );
    });

    testWidgets('is read out as what it is', (tester) async {
      await pump(tester, size: 220);
      expect(find.bySemanticsLabel(kioskPlayQrLabel), findsOneWidget);
    });

    testWidgets('draws black modules on a white tile, the quiet zone '
        'white, every module a whole 5 × 5 device pixels', (tester) async {
      final boundary = await pump(tester, size: 220);
      final bytes = await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        image.dispose();
        return data!;
      });
      const side = 205;
      int luma(int x, int y) => bytes!.getUint8((y * side + x) * 4);
      // Every pixel of every module, by the matrix; the quiet zone white
      // (its rounded corners left aside).
      for (var y = 0; y < side; y++) {
        for (var x = 0; x < side; x++) {
          final r = y ~/ 5 - kioskQrQuietZone;
          final c = x ~/ 5 - kioskQrQuietZone;
          final inCode = r >= 0 && r < n && c >= 0 && c < n;
          final corner =
              (x < 8 || x >= side - 8) && (y < 8 || y >= side - 8);
          if (corner) continue;
          expect(
            luma(x, y),
            inCode && dark(r, c) ? 0 : 255,
            reason: 'pixel ($x, $y)',
          );
        }
      }
    });
  });
}
