/// The kiosk's player (0066): the match's YouTube video, embedded — an
/// `<iframe>` on the web, a WebView in the app — never the YouTube app.
/// Both take the video id and `interactive`: false while the player must
/// not take touches (a drag of the window, a route above the kiosk).
library;

export 'kiosk_stream_view_io.dart'
    if (dart.library.js_interop) 'kiosk_stream_view_web.dart'
    show KioskStreamView;
