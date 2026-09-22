/// The address a tablet has to open to become the alley's board.
///
/// It is the app's own address plus the kiosk-login route, and the app is
/// deployed to more than one place — rezervator.online at the root, an alley
/// hosting its own copy under a sub-path (SETUP.md), a preview build on a
/// laptop — so the address is DERIVED from where the app is actually running
/// rather than written down anywhere. Only the Android build has no address
/// of its own; there the caller passes the public web one. The public overview's
/// address (0043) follows the same rules.
library;

/// The root the app is served at, ending with exactly one '/' — a full page
/// URL is fine, its query and fragment are dropped, which is what makes it
/// safe to pass `Uri.base` while the admin sits deep inside the app on a
/// route of their own.
String appRootUrl(Uri appUrl) {
  final root = Uri(
    scheme: appUrl.scheme,
    host: appUrl.host,
    port: appUrl.hasPort ? appUrl.port : null,
    // A deployment under a sub-path (…/rezervator/) has to keep it; the
    // path of a hash route ("/#/kiosk-login") never reaches the server, so
    // there is nothing else in here to strip.
    path: appUrl.path,
  ).toString();
  return root.endsWith('/') ? root : '$root/';
}

/// The kiosk address for an app served at [appUrl].
String kioskUrlFrom(Uri appUrl) => '${appRootUrl(appUrl)}#/kiosk-login';

/// The public overview (0043) of the alley published under [slug].
String publicUrlFrom(Uri appUrl, String slug) =>
    '${appRootUrl(appUrl)}#/prehled/$slug';
