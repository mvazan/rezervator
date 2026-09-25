/// A failed magic link on the web comes back as a URL fragment —
/// `#error=access_denied&error_code=otp_expired&…` — and with the hash URL
/// strategy GoRouter reads that fragment as the location
/// `/error=access_denied&…`, which matches no route, so the user got
/// „Page Not Found“ instead of the sign-in screen. supabase_flutter has
/// already turned the fragment into an auth error; the sign-in screen shows
/// it in Czech, so the location only has to lead there.
library;

final _authError = RegExp(r'^/(error|error_code|error_description)=');

/// `/` for a location that is a failed magic link's fragment, else null.
String? authErrorRedirect(Uri location) =>
    _authError.hasMatch(location.path) ? '/' : null;
