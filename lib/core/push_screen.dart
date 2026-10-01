import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Location of [pushScreen]'s pages; see the route in main.dart.
const pushedScreenPath = '/obrazovka';

/// Opens a full screen on top of the current one. Through GoRouter, so on
/// the web each screen is a browser history entry: the browser's back
/// button closes it instead of leaving the site (a plain Navigator.push
/// leaves the address bar and history untouched). Without a GoRouter above
/// [context] (a bare widget test) it is an ordinary push.
Future<T?> pushScreen<T>(BuildContext context, WidgetBuilder builder) {
  final router = GoRouter.maybeOf(context);
  if (router == null) {
    return Navigator.of(context)
        .push<T>(MaterialPageRoute<T>(builder: builder));
  }
  return router.push<T>(pushedScreenPath, extra: builder);
}
