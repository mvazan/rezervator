/// The address a tablet has to open to become the alley's board.
///
/// It is the app's own address plus the kiosk-login route, and the app is
/// deployed to more than one place — rezervator.online at the root, an alley
/// hosting its own copy under a sub-path (SETUP.md), a preview build on a
/// laptop — so the address is DERIVED from where the app is actually running
/// rather than written down anywhere. Only the Android build has no address
/// of its own; there the caller passes the public web one.
library;

/// The kiosk address for an app served at [appUrl] — a full page URL is
/// fine, its query and fragment are dropped, which is what makes it safe to
/// pass `Uri.base` while the admin sits deep inside the app on a route of
/// their own.
String kioskUrlFrom(Uri appUrl) {
  final root = Uri(
    scheme: appUrl.scheme,
    host: appUrl.host,
    port: appUrl.hasPort ? appUrl.port : null,
    // A deployment under a sub-path (…/rezervator/) has to keep it; the
    // path of a hash route ("/#/kiosk-login") never reaches the server, so
    // there is nothing else in here to strip.
    path: appUrl.path,
  ).toString();
  return '${root.endsWith('/') ? root : '$root/'}#/kiosk-login';
}
