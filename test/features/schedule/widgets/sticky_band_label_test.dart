import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/features/schedule/widgets/calendar_board.dart';

/// Where a band's one label stands while the board scrolls, like a
/// multi-day event's title in Google Calendar: with the band's start in
/// view it rides at the start; the band run off to the left, it sticks to
/// the row's left edge; near the band's end the end pushes it along; a
/// band too narrow for it keeps it at its start. All in the header list's
/// scroll space.
void main() {
  // A band from 100 to 900 px, a 120 px label.
  double left(double viewportLeft, {double bandEnd = 900}) =>
      stickyBandLabelLeft(
        viewportLeft: viewportLeft,
        bandStart: 100,
        bandEnd: bandEnd,
        labelWidth: 120,
      );

  test('the band\'s start in view: the label rides at its start', () {
    expect(left(0), 106);
    expect(left(100), 106);
    // The band's start a little off to the right of the row's edge.
    expect(left(60), 106);
  });

  test('the band run off to the left: stuck to the row\'s left edge', () {
    expect(left(101), 107);
    expect(left(400), 406);
    // Up to where it just fits before the end's padding.
    expect(left(768), 774);
  });

  test('near the band\'s end the end pushes it left; it never passes the '
      'end', () {
    expect(left(769), 774);
    expect(left(800), 774);
    // The whole band off to the left: still against its end.
    expect(left(2000), 774);
  });

  test('a band narrower than the label keeps it at its start', () {
    expect(left(0, bandEnd: 200), 106);
    expect(left(150, bandEnd: 200), 106);
    expect(left(500, bandEnd: 200), 106);
  });

  test('positions change continuously as the row scrolls', () {
    var last = left(0);
    for (var x = 0.0; x <= 1000; x += 0.5) {
      final now = left(x);
      expect((now - last).abs(), lessThanOrEqualTo(0.5), reason: '$x');
      last = now;
    }
  });

  test('a band begun before the list\'s first column: negative start', () {
    expect(
      stickyBandLabelLeft(
        viewportLeft: 0,
        bandStart: -500,
        bandEnd: 700,
        labelWidth: 80,
      ),
      6,
    );
    expect(
      stickyBandLabelLeft(
        viewportLeft: 0,
        bandStart: -500,
        bandEnd: 700,
        labelWidth: 80,
        padding: 10,
      ),
      10,
    );
  });
}
