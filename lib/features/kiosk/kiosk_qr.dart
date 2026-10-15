/// The kiosk's QR code of Rezervátor on Google Play, for the „Jak začít“
/// card (kiosk_guide.dart): its modules bundled as text, drawn as a black
/// code on a white tile — no QR package, nothing encoded on the device.
///
/// Generated once, outside the app, with the Dart package qr 3.0.2
/// (pub.dev, BSD-3-Clause) from [kioskPlayUrl]: byte mode, error correction
/// level L — a screen is never scratched or smudged like a printed code,
/// so the lowest level gives the largest modules — which makes version 4,
/// 33 × 33 modules, mask 2 (the package's pick). To generate it again: a
/// scratch package depending on `qr: 3.0.2`, `QrImage(QrCode.fromData(data:
/// kioskPlayUrl, errorCorrectLevel: QrErrorCorrectLevel.L))`, one string per
/// row of `isDark(row, col)`. Checked by decoding the rows back to the URL
/// (macOS Core Image's QR detector); after any change, scan the kiosk's
/// screen with a phone before a release.
library;

import 'package:flutter/material.dart';

/// Where the code leads: Rezervátor's page on Google Play (as
/// UpdateScreen.playUrl).
const kioskPlayUrl =
    'https://play.google.com/store/apps/details?id=cz.kuzelky.rezervator';

/// What a screen reader says for the code.
const kioskPlayQrLabel = 'QR kód: Rezervátor na Google Play';

/// The light modules around a code that a scanner needs to find it (the
/// standard's quiet zone), on every side.
const kioskQrQuietZone = 4;

/// [kioskPlayUrl] as a QR code, one string per row, top to bottom: '#' a
/// dark module, '.' a light one.
const kioskPlayQr = <String>[
  '#######...#.###.########..#######',
  '#.....#.#.#..#.##.#.#.....#.....#',
  '#.###.#.....#..##..###.#..#.###.#',
  '#.###.#.###.####.#.##.###.#.###.#',
  '#.###.#..#......#.##.#.#..#.###.#',
  '#.....#.##.##.##....###.#.#.....#',
  '#######.#.#.#.#.#.#.#.#.#.#######',
  '.........###..#...##.##..........',
  '#####.####.#.######.#....#.#.#.#.',
  '#####...#.#.#.#.##.##..#..#...###',
  '##....###.#..#.#......#..##.##.#.',
  '..#.##..#...#...#...#######.#.#..',
  '.#######.##.###..#.#..#..#.###...',
  '.###.#........#...####.#..#....##',
  '#.#..##.##.########.##...#..#..#.',
  '..#.#..###.#...#.....###.##...#..',
  '.######....#.##.##.#..####.##..#.',
  '##.#.#....#.#...##.######.#..#.##',
  '......#.#.#....####.##...#####.#.',
  '.###....#...#.#...#..#......#.#..',
  '....#.#.###.###..##...####.##..#.',
  '#..##..#.#....#.########..##.#.##',
  '#.#.###..####.##.#...#...#...#.#.',
  '#..#...#..##...##.#.##.#.#.####..',
  '#.##..##.###.##..#..#.########..#',
  '........###.##..#######.#...#.#.#',
  '#######.###..######.#..##.#.#.##.',
  '#.....#..#..#.###...#####...#####',
  '#.###.#.###.####.#......#####....',
  '#.###.#.###...#.#..##..#....##...',
  '#.###.#.#..###.#......#.#.#...##.',
  '#.....#.##.#........###..##..##..',
  '#######.#..##...##....###.##...#.',
];

/// The side of the tile for a code of [modules] × [modules] (its quiet zone
/// around it), in logical pixels, given [size] logical pixels of room on a
/// screen of [dpr] device pixels to one: every module the same whole number
/// of device pixels, m = ⌊size · dpr / (modules + 8)⌋, so no module is a
/// pixel wider than its neighbour. 0 when m < 3 — too small to scan from a
/// step away.
double kioskQrTile(double size, double dpr, int modules) {
  final span = modules + 2 * kioskQrQuietZone;
  // The epsilon keeps a size that is itself a tile (m · span / dpr) from
  // flooring a module short on the division's rounding.
  final m = (size * dpr / span + 1e-9).floor();
  return m < 3 ? 0 : m * span / dpr;
}

/// A QR code of [rows] (as [kioskPlayQr]): black modules on a white tile
/// with the quiet zone, in either kiosk theme — a light code on a dark card
/// is one that some scanners do not read. As large as fits [size]
/// ([kioskQrTile]), drawn in device pixels without anti-aliasing, so the
/// edges are sharp even at the web kiosk's lower resolution.
class KioskQr extends StatelessWidget {
  const KioskQr({
    super.key,
    required this.rows,
    required this.size,
    this.semanticLabel,
  });

  final List<String> rows;

  /// The room the tile may take, in logical pixels.
  final double size;

  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final tile = kioskQrTile(size, dpr, rows.length);
    return Semantics(
      label: semanticLabel,
      image: true,
      child: SizedBox.square(
        dimension: tile,
        child: tile == 0
            ? null
            : CustomPaint(painter: _QrPainter(rows: rows, dpr: dpr)),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  const _QrPainter({required this.rows, required this.dpr});

  final List<String> rows;
  final double dpr;

  @override
  void paint(Canvas canvas, Size size) {
    final span = rows.length + 2 * kioskQrQuietZone;
    // One module in device pixels — a whole number by kioskQrTile.
    final m = (size.width * dpr / span).roundToDouble();
    canvas.save();
    // Device pixels from here on: whole modules, whose edges snap to the
    // pixels without anti-aliasing.
    canvas.scale(1 / dpr);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, span * m, span * m),
        // Rounded within the quiet zone, never into the code.
        Radius.circular(m * 1.5),
      ),
      Paint()..color = Colors.white,
    );
    final dark = Path();
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      for (var c = 0; c < row.length; c++) {
        if (row.codeUnitAt(c) != 0x23) continue; // '#'
        dark.addRect(
          Rect.fromLTWH(
            (c + kioskQrQuietZone) * m,
            (r + kioskQrQuietZone) * m,
            m,
            m,
          ),
        );
      }
    }
    canvas.drawPath(
      dark,
      Paint()
        ..color = Colors.black
        // Anti-aliased, two modules side by side would show a hairline
        // seam where their edges meet.
        ..isAntiAlias = false,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.rows != rows || old.dpr != dpr;
}
