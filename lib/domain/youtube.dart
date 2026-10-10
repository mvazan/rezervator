/// YouTube links as the federation site hands them out with a match
/// (`priority_slots.video_url`): the video id out of any of the usual
/// address forms, and the address the kiosk's player embeds (0066).
library;

final _id = RegExp(r'^[A-Za-z0-9_-]{11}$');

/// The video id in [url] — `youtube.com/watch?v=ID` (any other query
/// parameters, `www.` or `m.`), `youtu.be/ID`, `youtube.com/live/ID`,
/// `/embed/ID`, `/shorts/ID` — or null when it is not a YouTube video.
String? youtubeVideoId(String url) {
  final text = url.trim();
  final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
  if (uri == null) return null;
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^(www|m)\.'), '');
  final segments = uri.pathSegments;
  String? candidate;
  if (host == 'youtu.be') {
    candidate = segments.firstOrNull;
  } else if (host == 'youtube.com' || host == 'youtube-nocookie.com') {
    if (segments.isNotEmpty && segments.first == 'watch') {
      candidate = uri.queryParameters['v'];
    } else if (segments.length >= 2 &&
        const {'live', 'embed', 'shorts', 'v'}.contains(segments.first)) {
      candidate = segments[1];
    }
  }
  return candidate != null && _id.hasMatch(candidate) ? candidate : null;
}

/// The address the kiosk's player loads for [id]: the privacy-enhanced
/// domain, muted autoplay (the only autoplay a browser or a WebView
/// allows), inline, YouTube's own fullscreen off (the window has its own —
/// a WebView could not show YouTube's), no strangers' videos at the end.
String youtubeEmbedUrl(String id) =>
    'https://www.youtube-nocookie.com/embed/$id'
    '?autoplay=1&mute=1&playsinline=1&controls=1&fs=0&rel=0&modestbranding=1';

/// The https origin the app's player gives its host page (`baseUrl` of
/// `loadHtmlString`): a top-level load of the embed address carries no
/// Referer, and YouTube refuses that (player error 153); as an iframe of a
/// page with an origin it plays like on the web.
const kioskStreamHostOrigin = 'https://rezervator.online';

/// The one-line page the app's player loads around [embedUrl]: the embed
/// fills it, sandboxed so the player's own links (the title, the logo,
/// „Watch on YouTube“) open nothing — no popups, no navigation out.
String kioskStreamHostPage(String embedUrl) =>
    '<!doctype html><html><head>'
    '<meta name="viewport" content="width=device-width, initial-scale=1">'
    '</head><body style="margin:0;background:#000">'
    '<iframe src="$embedUrl" '
    'allow="autoplay; encrypted-media; picture-in-picture" '
    'sandbox="allow-scripts allow-same-origin allow-presentation" '
    'style="border:0;width:100vw;height:100vh"></iframe>'
    '</body></html>';
