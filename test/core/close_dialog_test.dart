import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart';

/// Closing a dialog AFTER an await. `Navigator.pop` pops whatever is on
/// top, which by then need not be the dialog at all: in 1.2.4 a save that
/// finished while the Oddíl dropdown was open popped the MENU with the
/// dialog's `true`. The menu's result type is not the dialog's, so the pop
/// threw halfway through and left the navigator in pieces — the menu still
/// on screen, the dialog already counted as the top route, and finally a
/// back button with nothing to pop (Sentry REZERVATOR-4, -5 and -6, all
/// three of them from that one save).
void main() {
  /// A page with a dialog that saves asynchronously: [save] decides when
  /// the save finishes, and the dialog then closes itself with `true`.
  Widget app(Completer<bool> save, {required bool cancelable}) => MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                const Text('STRÁNKA'),
                FilledButton(
                  onPressed: () => showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('Přidat hráče bez účtu'),
                      content: DropdownButtonFormField<String?>(
                        key: const Key('oddil'),
                        initialValue: null,
                        items: const [
                          DropdownMenuItem(
                              value: null, child: Text('Bez oddílu')),
                          DropdownMenuItem(value: 'v', child: Text('Veverky')),
                        ],
                        onChanged: (_) {},
                      ),
                      actions: [
                        if (cancelable)
                          TextButton(
                            onPressed: () => Navigator.of(dialogContext).pop(),
                            child: const Text('Zrušit'),
                          ),
                        FilledButton(
                          onPressed: () async {
                            final ok = await save.future;
                            if (!dialogContext.mounted) return;
                            closeDialog(dialogContext, ok);
                          },
                          child: const Text('Uložit'),
                        ),
                      ],
                    ),
                  ),
                  child: const Text('OTEVŘÍT'),
                ),
              ],
            ),
          ),
        ),
      );

  testWidgets('closes ITS dialog even with a dropdown menu on top of it',
      (tester) async {
    final save = Completer<bool>();
    await tester.pumpWidget(app(save, cancelable: false));
    await tester.tap(find.text('OTEVŘÍT'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uložit'));
    await tester.pump();

    // The save is in flight and the user opens the Oddíl dropdown: its
    // menu is a route of its own, pushed OVER the dialog.
    await tester.tap(find.byKey(const Key('oddil')));
    await tester.pumpAndSettle();
    expect(find.text('Veverky'), findsOneWidget, reason: 'the menu is up');

    save.complete(true);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Přidat hráče bez účtu'), findsNothing);
    expect(find.text('Veverky'), findsNothing,
        reason: 'the menu went out with the dialog it belonged to');
    expect(find.text('STRÁNKA'), findsOneWidget);
  });

  testWidgets('a dialog already on its way out leaves the page alone',
      (tester) async {
    final save = Completer<bool>();
    await tester.pumpWidget(app(save, cancelable: true));
    await tester.tap(find.text('OTEVŘÍT'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uložit'));
    await tester.pump();

    // Zrušit while „Ukládám…" runs: the dialog starts closing, but its
    // subtree lives on through the animation — and the save lands right
    // in that window.
    await tester.tap(find.text('Zrušit'));
    await tester.pump(const Duration(milliseconds: 30));
    save.complete(true);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Přidat hráče bez účtu'), findsNothing);
    expect(find.text('STRÁNKA'), findsOneWidget,
        reason: 'the page underneath is not ours to pop');
  });
}
