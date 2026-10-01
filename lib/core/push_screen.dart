import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Location of [pushScreen]'s pages; see the route in main.dart.
const pushedScreenPath = '/obrazovka';

/// Builders of the screens opened with [pushScreen], by the id that travels
/// as the route's `extra`. A builder cannot go into the browser's history
/// state (it is JSON-encoded, a function is dropped), but a step back or
/// forward rebuilds the page from that state, so the state carries only the
/// id and the builder stays here. Bounded: the oldest ones go first.
final _builders = <int, WidgetBuilder>{};
const _maxBuilders = 64;
var _nextId = 0;

/// The screen [id] opens, or null once the page was reloaded (the ids are
/// gone with the old page, the browser's history still holds them).
WidgetBuilder? pushedScreenBuilder(Object? id) =>
    id is int ? _builders[id] : null;

/// Page of the [pushedScreenPath] route: the screen, or the home screen when
/// its builder is gone. The route's `redirect` only sees a location being
/// opened, not the pages a history step restores on top of it, hence this.
Widget buildPushedScreen(BuildContext context, Object? id) {
  final builder = pushedScreenBuilder(id);
  return builder == null ? const _BackHome() : builder(context);
}

/// Opens a full screen on top of the current one. Through GoRouter, so on
/// the web each screen is a browser history entry: the browser's back
/// button closes it instead of leaving the site (a plain Navigator.push
/// leaves the address bar and history untouched). Without a GoRouter above
/// [context] (a bare widget test) it is an ordinary push.
Future<T?> pushScreen<T>(BuildContext context, WidgetBuilder builder) {
  final router = GoRouter.maybeOf(context);
  if (router == null) {
    return Navigator.of(
      context,
    ).push<T>(MaterialPageRoute<T>(builder: builder));
  }
  final id = _nextId++;
  _builders[id] = builder;
  if (_builders.length > _maxBuilders) _builders.remove(_builders.keys.first);
  return router.push<T>(pushedScreenPath, extra: id);
}

class _BackHome extends StatefulWidget {
  const _BackHome();

  @override
  State<_BackHome> createState() => _BackHomeState();
}

class _BackHomeState extends State<_BackHome> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.go('/');
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}
