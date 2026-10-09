import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/duels.dart';

void main() {
  Duel duel(int position, DuelState state) => Duel(
    position: position,
    home: null,
    away: null,
    lanes: const [],
    state: state,
    playedLanes: 0,
    diff: null,
    shownHome: null,
    shownAway: null,
    pointWinner: null,
    pointSplit: false,
    decidedByPins: false,
    walkover: false,
  );

  List<Duel> six(Map<int, DuelState> states) => [
    for (var p = 1; p <= 6; p++) duel(p, states[p] ?? DuelState.waiting),
  ];

  const done = DuelState.done;
  const playing = DuelState.playing;

  test('nothing started: nowhere to go', () {
    expect(kioskLiveScrollTarget(six({}), laneCount: 4), isNull);
  });

  test('threes on six lanes: 1, 4', () {
    expect(
      kioskLiveScrollTarget(six({1: playing, 2: playing, 3: playing}),
          laneCount: 6),
      1,
    );
    expect(
      kioskLiveScrollTarget(
        six({1: done, 2: done, 3: done, 4: playing, 5: playing, 6: playing}),
        laneCount: 6,
      ),
      4,
    );
  });

  test('pairs on four lanes: 1, 3, 5', () {
    expect(
      kioskLiveScrollTarget(
        six({1: done, 2: done, 3: playing, 4: playing}),
        laneCount: 4,
      ),
      3,
    );
    expect(
      kioskLiveScrollTarget(
        six({1: done, 2: done, 3: done, 4: done, 5: playing, 6: playing}),
        laneCount: 4,
      ),
      5,
    );
  });

  test('between groups the alley decides the group size', () {
    expect(
      kioskLiveScrollTarget(
        six({1: done, 2: done, 3: done, 4: done}),
        laneCount: 4,
      ),
      3,
    );
    expect(
      kioskLiveScrollTarget(six({1: done, 2: done, 3: done}), laneCount: 6),
      1,
    );
  });

  test('an away match on other lanes: the duels being played decide', () {
    expect(
      kioskLiveScrollTarget(
        six({1: done, 2: done, 3: done, 4: playing, 5: playing, 6: playing}),
        laneCount: 4,
      ),
      4,
    );
  });
}
