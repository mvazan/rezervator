/// The web kiosk's „Nižší rozlišení“ (0065): draw at devicePixelRatio 1 and
/// let the display scale the picture up — fewer pixels a frame on a slow
/// display, softer text. Flutter reads the ratio as it boots, so the switch
/// is a flag in localStorage that web/index.html applies before
/// flutter_bootstrap.js, and flipping it reloads the page. Elsewhere (the
/// Android app) there is no page: [setKioskLowRes] does nothing.
library;

import 'kiosk_low_res_io.dart'
    if (dart.library.js_interop) 'kiosk_low_res_web.dart'
    as impl;

/// Stores [on] for the next start and reloads the page when it differs
/// from what this start was given.
void setKioskLowRes(bool on) => impl.setKioskLowRes(on);

/// Drops the stored choice, no reload: the page keeps the ratio it started
/// with, the next start is plain. For whatever is not the kiosk — a browser
/// that once ran the kiosk would otherwise stay at ratio 1 for whoever signs
/// in there next (the admin trying the kiosk on their phone).
void forgetKioskLowRes() => impl.forgetKioskLowRes();
