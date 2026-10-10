/// YouTube links as the federation site hands them out with a match
/// (`priority_slots.video_url`): the video id out of any of the usual
/// address forms, and the address the kiosk's player embeds (0066).
library;

import 'dart:convert';

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

/// Where the embed lives — and where its messages come from.
const youtubeEmbedOrigin = 'https://www.youtube-nocookie.com';

/// The address the kiosk's player loads for [id]: the privacy-enhanced
/// domain, muted autoplay (the only autoplay a browser or a WebView
/// allows), inline, YouTube's own fullscreen off (the window has its own —
/// a WebView could not show YouTube's), no strangers' videos at the end.
/// `enablejsapi` with the embedding page's [origin]: the player tells the
/// page its state ([youtubeHello]), so the window closes when the video
/// ends.
String youtubeEmbedUrl(String id, {required String origin}) =>
    '$youtubeEmbedOrigin/embed/$id'
    '?autoplay=1&mute=1&playsinline=1&controls=1&fs=0&rel=0&modestbranding=1'
    '&enablejsapi=1&origin=${Uri.encodeComponent(origin)}';

/// What the embedding page posts to the player to hear from it — the
/// iframe protocol YouTube's own IFrame API speaks: „listening“, then a
/// subscription to state changes. Every answer carries [id] back, so a
/// page with several players knows whose it is.
List<String> youtubeHello(String id) => [
  jsonEncode({'event': 'listening', 'id': id, 'channel': 'widget'}),
  jsonEncode({
    'event': 'command',
    'func': 'addEventListener',
    'args': ['onStateChange'],
    'id': id,
    'channel': 'widget',
  }),
];

/// The embed's message [data] as a map with the id it carries back, or
/// null when it is not one.
({String id, Map<dynamic, dynamic> message})? _fromPlayer(Object? data) {
  if (data is! String) return null;
  final Object? message;
  try {
    message = jsonDecode(data);
  } on FormatException {
    return null;
  }
  if (message is! Map || message['id'] == null) return null;
  return (id: '${message['id']}', message: message);
}

/// The id of the player that posted [data] — any message of the iframe
/// protocol: the player has heard the page's hello. Null otherwise.
String? youtubePlayerId(Object? data) => _fromPlayer(data)?.id;

/// The id of the player whose video has ended (state 0), read from a
/// message [data] the embed posted — as a state change, or as the player
/// state among delivered info. Null for anything else.
String? youtubeEndedId(Object? data) {
  final from = _fromPlayer(data);
  if (from == null) return null;
  final info = from.message['info'];
  final state = switch (from.message['event']) {
    'onStateChange' => info,
    'infoDelivery' when info is Map => info['playerState'],
    _ => null,
  };
  return state == 0 ? from.id : null;
}

/// The https origin the app's player gives its host page (`baseUrl` of
/// `loadHtmlString`): a top-level load of the embed address carries no
/// Referer, and YouTube refuses that (player error 153); as an iframe of a
/// page with an origin it plays like on the web.
const kioskStreamHostOrigin = 'https://rezervator.online';

/// The JavaScript channel the app's player listens on: the host page
/// passes it the player's state changes ([youtubeEndedId] reads them).
const kioskStreamChannel = 'KioskStream';

/// The page the app's player loads around [embedUrl]: the embed fills it,
/// sandboxed so the player's own links (the title, the logo, „Watch on
/// YouTube“) open nothing — no popups, no navigation out. Its script says
/// [youtubeHello] once the embed has loaded (again every second until the
/// player answers, ten times at most) and hands the player's state changes
/// to [kioskStreamChannel] — only those, not the many progress reports.
String kioskStreamHostPage(String embedUrl) =>
    '<!doctype html><html><head>'
    '<meta name="viewport" content="width=device-width, initial-scale=1">'
    '</head><body style="margin:0;background:#000">'
    '<iframe id="p" src="$embedUrl" '
    'allow="autoplay; encrypted-media; picture-in-picture" '
    'sandbox="allow-scripts allow-same-origin allow-presentation" '
    'style="border:0;width:100vw;height:100vh"></iframe>'
    '<script>(function(){'
    "var f=document.getElementById('p'),heard=false,n=0;"
    'var hello=${jsonEncode(youtubeHello('1'))};'
    'function say(){hello.forEach(function(m){'
    "f.contentWindow.postMessage(m,'$youtubeEmbedOrigin');});}"
    "f.addEventListener('load',function(){say();"
    'var t=setInterval(function(){'
    'if(heard||++n>=10){clearInterval(t);}else{say();}},1000);});'
    "window.addEventListener('message',function(e){"
    'if(e.source!==f.contentWindow)return;heard=true;'
    "if(typeof e.data==='string'&&(e.data.indexOf('playerState')>=0||"
    "e.data.indexOf('onStateChange')>=0)&&window.$kioskStreamChannel)"
    '$kioskStreamChannel.postMessage(e.data);});'
    '})();</script>'
    '</body></html>';
