import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/features/schedule/widgets/calendar_board.dart';

/// Where a band's one label stands and how wide it is while the board
/// scrolls, like a multi-day event's title in Google Calendar: it starts
/// at the band's visible start — the band's start while that is in view,
/// the row's left edge once the band runs off it — and where the band
/// left in view is narrower, it is cut there with an ellipsis; only below
/// two glyphs and the ellipsis does the band's end push it off to the
/// left. All in the header list's scroll space.
void main() {
  // A band from 100 to 900 px, a 120 px label, the least it is cut to
  // 24 px.
  ({double left, double width}) at(
    double viewportLeft, {
    double bandEnd = 900,
    double labelWidth = 120,
  }) => stickyBandLabel(
    viewportLeft: viewportLeft,
    bandStart: 100,
    bandEnd: bandEnd,
    labelWidth: labelWidth,
  );

  test('the band\'s start in view: the whole label rides at its start', () {
    expect(at(0), (left: 106.0, width: 120.0));
    expect(at(100), (left: 106.0, width: 120.0));
    // The band's start a little off to the right of the row's edge.
    expect(at(60), (left: 106.0, width: 120.0));
  });

  test('the band run off to the left: stuck to the row\'s left edge', () {
    expect(at(101), (left: 107.0, width: 120.0));
    expect(at(400), (left: 406.0, width: 120.0));
    // Up to where it just fits before the end's padding.
    expect(at(768), (left: 774.0, width: 120.0));
  });

  test('what is left of the band narrower than the label: it stays at the '
      'row\'s left edge, cut to the room before the end', () {
    expect(at(769), (left: 775.0, width: 119.0));
    expect(at(800), (left: 806.0, width: 88.0));
    // Down to the least it is cut to.
    expect(at(864), (left: 870.0, width: 24.0));
  });

  test('below the least, the band\'s end pushes it off to the left; it never '
      'passes the end', () {
    expect(at(865), (left: 870.0, width: 24.0));
    expect(at(890), (left: 870.0, width: 24.0));
    // The whole band off to the left: still against its end.
    expect(at(2000), (left: 870.0, width: 24.0));
  });

  test('a label narrower than the least is pushed whole', () {
    expect(at(868, labelWidth: 20), (left: 874.0, width: 20.0));
    expect(at(880, labelWidth: 20), (left: 874.0, width: 20.0));
  });

  test('a band narrower than the label: at its start, cut; its first day '
      'off the row, at the row\'s left edge, cut — not its middle', () {
    expect(at(0, bandEnd: 200), (left: 106.0, width: 88.0));
    expect(at(150, bandEnd: 200), (left: 156.0, width: 38.0));
    expect(at(500, bandEnd: 200), (left: 170.0, width: 24.0));
  });

  test('a band too narrow even for the least: at its start, cut to it', () {
    expect(at(0, bandEnd: 130), (left: 106.0, width: 18.0));
    expect(at(120, bandEnd: 130), (left: 106.0, width: 18.0));
    expect(at(0, bandEnd: 105), (left: 106.0, width: 0.0));
  });

  test('where it stands and how wide change continuously as the row '
      'scrolls', () {
    for (final (bandEnd, labelWidth) in [
      (900.0, 120.0),
      (200.0, 120.0),
      (900.0, 20.0),
      (130.0, 120.0),
    ]) {
      var last = at(-100, bandEnd: bandEnd, labelWidth: labelWidth);
      for (var x = -100.0; x <= 1000; x += 0.5) {
        final now = at(x, bandEnd: bandEnd, labelWidth: labelWidth);
        final why = '$bandEnd, $labelWidth at $x';
        expect(
          (now.left - last.left).abs(),
          lessThanOrEqualTo(0.5),
          reason: why,
        );
        expect(
          (now.width - last.width).abs(),
          lessThanOrEqualTo(0.5),
          reason: why,
        );
        // Never past the band's end.
        expect(
          now.left + now.width,
          lessThanOrEqualTo(bandEnd - 6),
          reason: why,
        );
        last = now;
      }
    }
  });

  test('a band begun before the list\'s first column: negative start', () {
    expect(
      stickyBandLabel(
        viewportLeft: 0,
        bandStart: -500,
        bandEnd: 700,
        labelWidth: 80,
      ),
      (left: 6.0, width: 80.0),
    );
    expect(
      stickyBandLabel(
        viewportLeft: 0,
        bandStart: -500,
        bandEnd: 700,
        labelWidth: 80,
        padding: 10,
      ),
      (left: 10.0, width: 80.0),
    );
  });

  test('the least is the caller\'s', () {
    expect(
      stickyBandLabel(
        viewportLeft: 860,
        bandStart: 100,
        bandEnd: 900,
        labelWidth: 120,
        minWidth: 33,
      ),
      (left: 861.0, width: 33.0),
    );
  });
}
