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
