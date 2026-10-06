import 'dart:io' show SocketException;

/// Transient connectivity failures (offline, DNS lookup failed, flaky mobile
/// signal) surface as uncaught Dart errors and Sentry marks them fatal —
/// but they aren't actionable bugs. The app already degrades gracefully:
/// the offline banner, the "Jsi offline" message (friendlyDbError), and
/// Supabase's own token-refresh retry. So they're pure noise in Sentry.
///
/// Kept pure and Flutter-free so it can be unit-tested; wired into
/// SentryFlutter's beforeSend in main.dart.
bool isTransientNetworkError(Object? throwable) {
  if (throwable is SocketException) return true;

  // Most reach Sentry wrapped (e.g. gotrue's AuthRetryableFetchException,
  // which by definition is a RETRYABLE fetch failure — a network problem,
  // not an auth-logic error), so match the signatures in the message too.
  final text = throwable.toString().toLowerCase();
  const markers = [
    'socketexception',
    'failed host lookup',
    'no address associated with hostname',
    'authretryablefetchexception',
    'clientexception',
    'connection refused',
    'connection reset',
    'connection closed',
    'connection timed out',
    'network is unreachable',
    'software caused connection abort',
    'operation timed out',
  ];
  return markers.any(text.contains);
}

/// The browser's „Script error.“: when a script of another origin fails —
/// a font or CanvasKit from a CDN, a browser extension, a half-loaded file
/// while a new build replaces the cached one — the browser withholds the
/// message and the stack from the page's `window.onerror`, so all Sentry
/// gets is these two words, no file, no line, no user (REZERVATOR-A: web
/// only, 0 users, from the first release on). There is nothing in it to
/// act on, and it keeps coming back as a „regression“.
///
/// [messages] are the values of the event's exceptions (and its message).
/// Kept pure like [isTransientNetworkError]; wired into beforeSend in
/// main.dart.
bool isOpaqueScriptError(Iterable<String?> messages) => messages.any((m) {
      final text = m?.trim().toLowerCase();
      return text == 'script error.' || text == 'script error';
    });
