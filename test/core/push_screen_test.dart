import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rezervator/core/push_screen.dart';

void main() {
  testWidgets('pushScreen opens a router page and pops with a result',
      (tester) async {
    int? result;
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await pushScreen<int>(
              context,
              (_) => Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).pop(7),
                  child: const Text('detail'),
                ),
              ),
            ),
            child: const Text('home'),
          ),
        ),
      ),
      GoRoute(
        path: pushedScreenPath,
        redirect: (_, state) =>
            pushedScreenBuilder(state.extra) == null ? '/' : null,
        builder: (context, state) => buildPushedScreen(context, state.extra),
      ),
    ]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));

    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsOneWidget);
    expect(router.state.uri.path, pushedScreenPath);

    await tester.tap(find.text('detail'));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(result, 7);
  });

  testWidgets('without a builder the location falls back home',
      (tester) async {
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const Text('home')),
      GoRoute(
        path: pushedScreenPath,
        redirect: (_, state) =>
            pushedScreenBuilder(state.extra) == null ? '/' : null,
        builder: (context, state) => const Text('never'),
      ),
    ]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.go(pushedScreenPath);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('without a GoRouter it is a plain push', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => pushScreen<void>(context, (_) => const Text('x')),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('x'), findsOneWidget);
  });

  // The browser's back button rebuilds the page from the history state,
  // which holds only what survives JSON: the builder must not be in it.
  testWidgets('a history step back restores a pushed screen', (tester) async {
    GoRouter.optionURLReflectsImperativeAPIs = true;
    addTearDown(() => GoRouter.optionURLReflectsImperativeAPIs = false);
    late GoRouter router;
    router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Builder(
          builder: (context) => TextButton(
            onPressed: () => pushScreen<void>(
              context,
              (_) => Builder(
                builder: (context) => TextButton(
                  onPressed: () => pushScreen<void>(
                      context, (_) => const Scaffold(body: Text('detail'))),
                  child: const Text('list'),
                ),
              ),
            ),
            child: const Text('home'),
          ),
        ),
      ),
      GoRoute(
        path: pushedScreenPath,
        redirect: (_, state) =>
            pushedScreenBuilder(state.extra) == null ? '/' : null,
        builder: (context, state) => buildPushedScreen(context, state.extra),
      ),
    ]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();
    // What the browser stores for the entry showing the list.
    final listEntry = router.routeInformationParser
        .restoreRouteInformation(router.routerDelegate.currentConfiguration)!;
    await tester.tap(find.text('list'));
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsOneWidget);

    // The back button: the list's entry comes back, JSON-encoded.
    final state = jsonDecode(jsonEncode(listEntry.state));
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      const JSONMethodCodec().encodeMethodCall(MethodCall(
        'pushRouteInformation',
        {'location': listEntry.uri.toString(), 'state': state},
      )),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('list'), findsOneWidget);
    expect(find.text('detail'), findsNothing);
  });
}
