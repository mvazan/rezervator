/// Short messages that must be READ, whatever is on screen at the time.
///
/// A `SnackBar` is painted by the Scaffold of the route it was asked from,
/// so a message raised while a dialog or a bottom sheet is open lands on the
/// page UNDERNEATH it: dimmed by the modal barrier, half-covered by the
/// dialog, and — with the keyboard up, which is exactly when a form
/// complains — behind the keyboard too. Validation like „Konec musí být po
/// začátku" was invisible at the moment it mattered.
///
/// So a message raised from a modal route goes into the ROOT overlay
/// instead, above the barrier and above the keyboard, dressed as the
/// snackbar it would otherwise have been. Everywhere else nothing changes:
/// the ScaffoldMessenger keeps doing its job, queueing and all.
library;

import 'dart:async';

import 'package:flutter/material.dart';

/// How long a message stays up — Material's own default for a snackbar.
const messageDuration = Duration(seconds: 4);

/// The message currently in the root overlay, if any: one at a time, the
/// way a ScaffoldMessenger shows one snackbar at a time.
OverlayEntry? _current;

void _remove() {
  final entry = _current;
  _current = null;
  if (entry != null && entry.mounted) entry.remove();
}

/// True when [context] sits inside a dialog, a bottom sheet or any other
/// route that draws a barrier over the page — the case a Scaffold's own
/// snackbar cannot reach.
bool isBehindBarrier(BuildContext context) =>
    ModalRoute.of(context) is PopupRoute;

/// Shows [message] the way the app's snackbars look, in the root overlay so
/// no barrier can cover it. Replaces whatever it is already showing.
void showOverlayMessage(BuildContext context, String message) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _remove();
  final entry = OverlayEntry(
    builder: (_) => _OverlayMessage(message: message, onDone: _remove),
  );
  _current = entry;
  overlay.insert(entry);
}

/// Drops the message immediately.
void dismissOverlayMessage() => _remove();

/// Whether a message is up right now — the only thing a test can ask about
/// an overlay entry without walking the tree.
@visibleForTesting
bool get overlayMessageVisible => _current?.mounted ?? false;

/// The message itself. The countdown lives HERE, in a State, rather than
/// beside the overlay entry: a timer owned by the widget dies with it — when
/// the message is replaced, when the app closes, when a test tears its tree
/// down — instead of outliving the tree and leaving a stray timer behind.
class _OverlayMessage extends StatefulWidget {
  const _OverlayMessage({required this.message, required this.onDone});

  final String message;
  final VoidCallback onDone;

  @override
  State<_OverlayMessage> createState() => _OverlayMessageState();
}

class _OverlayMessageState extends State<_OverlayMessage> {
  late final Timer _timer = Timer(messageDuration, widget.onDone);

  @override
  void initState() {
    super.initState();
    _timer; // start the countdown
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snackTheme = theme.snackBarTheme;
    // The keyboard is the whole point: a form complains while its field is
    // focused, so the message sits above the insets, not under them. Read
    // here, in the overlay's own build, so it moves when the keyboard does.
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    return Positioned(
      left: 0,
      right: 0,
      bottom: insets,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Material(
              color:
                  snackTheme.backgroundColor ?? theme.colorScheme.inverseSurface,
              elevation: snackTheme.elevation ?? 6,
              shape: snackTheme.shape ??
                  const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                  ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                // Tap to get it out of the way — a message over a dialog can
                // otherwise sit on the very button it is about.
                onTap: widget.onDone,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Text(
                    widget.message,
                    style: snackTheme.contentTextStyle ??
                        theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onInverseSurface,
                        ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
