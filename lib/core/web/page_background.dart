/// The colour behind the app on the web: the page's own background. The
/// browser shows it wherever Flutter has drawn nothing yet — above all for
/// the ~100 ms after the window changes shape (a turn of the phone), when it
/// scales the last frame to fit the new size and fills the rest with the
/// page background. White under a dark theme is a flash; the theme's own
/// background is not.
///
/// On the other platforms there is no page: [setPageBackground] does
/// nothing.
library;

import 'package:flutter/material.dart';

import 'page_background_io.dart'
    if (dart.library.js_interop) 'page_background_web.dart'
    as impl;

/// Keeps the page's background at the theme's scaffold colour (web only).
class PageBackground extends StatelessWidget {
  const PageBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    impl.setPageBackground(Theme.of(context).scaffoldBackgroundColor);
    return child;
  }
}
