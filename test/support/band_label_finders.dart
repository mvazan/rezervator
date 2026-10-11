import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/features/schedule/widgets/calendar_board.dart';

/// The pieces ([BoardBand]) of the band labelled [label] — give each band
/// in a test its own label.
Finder bandPieces(String label) => find.byWidgetPredicate(
  (w) => w is BoardBand && w.segment.label == label,
  description: 'BoardBand "$label"',
);

/// The band's [label] as drawn across the board's headers: a copy in each
/// piece it crosses, clipped to that piece's strip, so the copies read as
/// one text. Checks it is ONE run — drawn at least once, every copy on one
/// rect, drawn by exactly the pieces whose strip that rect crosses — and
/// returns the rect.
Rect bandLabelRun(WidgetTester tester, String label) {
  final pieces = bandPieces(label);
  final copies = find.descendant(of: pieces, matching: find.text(label));
  final count = copies.evaluate().length;
  expect(count, greaterThan(0), reason: '"$label" is not drawn');
  final run = tester.getRect(copies.first);
  for (var i = 1; i < count; i++) {
    final copy = tester.getRect(copies.at(i));
    expect(copy.left, closeTo(run.left, 0.01), reason: 'copy $i of "$label"');
    expect(copy.width, closeTo(run.width, 0.01), reason: 'copy $i of "$label"');
    expect(copy.top, run.top, reason: 'copy $i of "$label"');
  }
  for (var i = 0; i < pieces.evaluate().length; i++) {
    final piece = pieces.at(i);
    final strip = tester.getRect(
      find.descendant(of: piece, matching: find.byType(Material)),
    );
    // Touching at a column's edge is a float's call either way.
    if ((strip.left - run.right).abs() < 0.01 ||
        (strip.right - run.left).abs() < 0.01) {
      continue;
    }
    final crosses = strip.left < run.right && strip.right > run.left;
    expect(
      find.descendant(of: piece, matching: find.text(label)),
      crosses ? findsOneWidget : findsNothing,
      reason: 'piece $i of "$label" at $strip, the label at $run',
    );
  }
  return run;
}
