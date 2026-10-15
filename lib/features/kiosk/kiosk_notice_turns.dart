/// The notices' turns on the kiosk, one rule for the status bar's headline
/// and the panel's card: the notice shown has a one-shot timer of its own,
/// re-armed after every step (the timer's or a swipe's), so each gets a turn
/// of its own — twice the admin's for a fresh one when the admin wants fresh
/// notices shown longer (0081, `kioskNoticeTurn`). A new notice on top is
/// shown at once, fewer notices keep the shown one within them, and a change
/// of the turn or of what makes a notice fresh starts the shown one's turn
/// over.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../domain/kiosk_panel.dart' show kioskNoticeTurn;
import '../../domain/models.dart';

/// What the turns were last armed with: the id of the notice on top and
/// everything the length of a turn depends on.
typedef _Armed = ({
  String? top,
  Duration turn,
  KioskNoticesFresh fresh,
  int freshDays,
});

/// The index, the timer and their reconciliation with the widget's notices,
/// for a state that shows one of several notices at a time. The state says
/// what it shows through the getters and draws [noticeIndex]; a swipe calls
/// [step].
mixin KioskNoticeTurns<T extends StatefulWidget> on State<T> {
  /// Newest first (`kioskNotices`).
  List<Message> get notices;

  /// The admin's turn.
  Duration get turn;

  /// What a fresh notice gets (0081) and for how many days it is fresh.
  KioskNoticesFresh get fresh;
  int get freshDays;

  /// The kiosk's clock when a turn is armed: a notice stops being fresh as
  /// the minutes go by.
  DateTime get now;

  Timer? _timer;
  int _index = 0;
  late _Armed _armed;

  /// The notice shown, always within [notices] (which must not be empty).
  int get noticeIndex =>
      notices.isEmpty ? 0 : _index.clamp(0, notices.length - 1);

  _Armed _current() => (
    top: notices.firstOrNull?.id,
    turn: turn,
    fresh: fresh,
    freshDays: freshDays,
  );

  @override
  void initState() {
    super.initState();
    _armed = _current();
    _start();
  }

  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);
    final was = _armed;
    final seen = _armed = _current();
    if (seen.top != was.top) {
      // A new notice on top (or the order changed): the newest at once,
      // for a whole turn of its own.
      _index = 0;
      _start();
    } else if (_index >= notices.length) {
      // Fewer notices: the last one, so the counter or a dot stays within
      // them.
      _index = notices.isEmpty ? 0 : notices.length - 1;
      _start();
    } else if (seen != was) {
      _start();
    }
  }

  /// A turn for the notice shown: one-shot, re-armed after every step.
  void _start() {
    _timer?.cancel();
    final list = notices;
    if (list.isEmpty) return;
    _timer = Timer(
      kioskNoticeTurn(
        list[noticeIndex],
        now: now,
        turn: turn,
        fresh: fresh,
        days: freshDays,
      ),
      () => step(1),
    );
  }

  /// To the next ([direction] 1) or previous (-1) notice — on the timer or
  /// by a swipe; either way the next turn is a whole one away.
  void step(int direction) {
    if (!mounted) return;
    final n = notices.length;
    if (n > 1) setState(() => _index = (_index + direction) % n);
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
