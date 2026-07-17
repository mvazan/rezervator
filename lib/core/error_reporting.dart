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
