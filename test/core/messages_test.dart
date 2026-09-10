import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/messages.dart';
import 'package:rezervator/core/ui.dart';

/// Where a message ends up when something modal is on screen. A Scaffold
/// paints its snackbar on the route UNDERNEATH a dialog, so validation like
/// „Konec musí být po začátku" used to appear below the barrier — dimmed,
/// half-covered by the dialog, and behind the open keyboard.
void main() {
  tearDown(dismissOverlayMessage);

  /// A page with a button that raises a message from the PAGE's context,
  /// and one that opens a dialog raising it from the DIALOG's context.
  Widget app({double keyboard = 0}) => MaterialApp(
        // Above the Navigator, so the ROOT OVERLAY sees it — which is where
        // the keyboard's inset comes from in a running app, and the whole
        // reason the message can dodge it.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(viewInsets: EdgeInsets.only(bottom: keyboard)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Builder(
            builder: (_) => Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Builder(
                      builder: (pageContext) => ElevatedButton(
                        onPressed: () => snack(pageContext, 'Ze stránky'),
                        child: const Text('page'),
                      ),
                    ),
                    Builder(
                      builder: (pageContext) => ElevatedButton(
                        onPressed: () => showDialog<void>(
                          context: pageContext,
                          builder: (dialogContext) => AlertDialog(
                            title: const Text('Přidat pronájem'),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    snack(dialogContext, 'Konec musí být po začátku.'),
                                child: const Text('Uložit'),
                              ),
                            ],
                          ),
                        ),
                        child: const Text('dialog'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('from a page it is the ordinary snackbar', (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.text('page'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(SnackBar, 'Ze stránky'), findsOneWidget);
    expect(overlayMessageVisible, isFalse);
  });

  testWidgets('from a dialog it goes into the root overlay, above the barrier',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.text('dialog'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    expect(find.text('Konec musí být po začátku.'), findsOneWidget);
    expect(overlayMessageVisible, isTrue);
    expect(find.byType(SnackBar), findsNothing,
        reason: 'a Scaffold snackbar would sit under the barrier');

    // The dialog is still open — the message did not replace it.
    expect(find.text('Přidat pronájem'), findsOneWidget);
    dismissOverlayMessage();
  });

  testWidgets('the keyboard does not cover it', (tester) async {
    await tester.pumpWidget(app(keyboard: 300));
    await tester.tap(find.text('dialog'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    final screen = tester.getSize(find.byType(MaterialApp)).height;
    final message = tester.getRect(find.text('Konec musí být po začátku.'));
    expect(message.bottom, lessThanOrEqualTo(screen - 300),
        reason: 'a form complains while its field is focused');
    dismissOverlayMessage();
  });

  testWidgets('one message at a time, and a tap gets it out of the way',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.text('dialog'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();
    expect(find.text('Konec musí být po začátku.'), findsOneWidget);

    await tester.tap(find.text('Konec musí být po začátku.'));
    await tester.pumpAndSettle();
    expect(find.text('Konec musí být po začátku.'), findsNothing);
    expect(overlayMessageVisible, isFalse);
  });

  testWidgets('it goes away on its own', (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.text('dialog'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();
    expect(overlayMessageVisible, isTrue);

    await tester.pump(messageDuration);
    await tester.pumpAndSettle();
    expect(find.text('Konec musí být po začátku.'), findsNothing);
  });
}
