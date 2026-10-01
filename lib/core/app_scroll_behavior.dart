import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

/// Flutter's default leaves mouse and trackpad out of the devices that can
/// drag a scrollable, so on the desktop web a touchpad swipe (Windows
/// precision touchpads report it as a pan/zoom gesture, not wheel ticks)
/// or a click-and-drag scrolled nothing and swiped no day pager page. The
/// wheel still works either way.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}
