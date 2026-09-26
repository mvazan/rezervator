/// A failed magic link on the web comes back as a URL fragment —
/// `#error=access_denied&error_code=otp_expired&…` — and with the hash URL
/// strategy GoRouter reads that fragment as the location
/// `/error=access_denied&…`, which matches no route, so the user got
/// „Page Not Found“ instead of the sign-in screen. supabase_flutter has
/// already turned the fragment into an auth error; the sign-in screen shows
/// it in Czech, so the location only has to lead there.
///
/// A successful one ends the same way: GoTrue adds its own `sb` marker to
/// the fragment (`#access_token=…&sb=&token_type=…`), supabase_flutter 2.16
/// strips the tokens but not `sb`, and `#sb` became the location `/sb` —
/// „Page Not Found“ right after signing in. Any location that is a leftover
/// auth parameter goes home as well.
library;

final _authFragment = RegExp(
  r'^/(error|error_code|error_description|sb|access_token|refresh_token'
  r'|expires_at|expires_in|token_type|type|provider_token'
  r'|provider_refresh_token|code)(=|&|$)',
);

/// `/` for a location that is a magic link's leftover fragment — failed or
/// successful — else null.
String? authErrorRedirect(Uri location) =>
    _authFragment.hasMatch(location.path) ? '/' : null;
