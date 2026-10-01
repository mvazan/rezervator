import 'package:flutter/material.dart';
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
        redirect: (_, state) => state.extra is WidgetBuilder ? null : '/',
        builder: (context, state) => (state.extra! as WidgetBuilder)(context),
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
        redirect: (_, state) => state.extra is WidgetBuilder ? null : '/',
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
}
