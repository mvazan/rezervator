import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import '../../../domain/youtube.dart';

const _viewType = 'rezervator-kiosk-stream';

/// The iframes alive, by platform view id — kept so [KioskStreamView]
/// can switch their pointer events.
final _frames = <int, web.HTMLIFrameElement>{};

/// Each player's „the video has ended“, by platform view id.
final _onEnded = <int, VoidCallback>{};

/// The hello repeated until the player answers, by platform view id.
final _hellos = <int, Timer>{};
var _registered = false;

/// Says [youtubeHello] to the player [viewId] — once its page has loaded,
/// then every second until it answers, ten times at most (the player may
/// not be listening yet when the page is).
void _greet(int viewId) {
  void say() {
    for (final message in youtubeHello('$viewId')) {
      _frames[viewId]?.contentWindow?.postMessage(
        message.toJS,
        youtubeEmbedOrigin.toJS,
      );
    }
  }

  say();
  var left = 9;
  _hellos.remove(viewId)?.cancel();
  _hellos[viewId] = Timer.periodic(const Duration(seconds: 1), (t) {
    if (--left < 0) {
      t.cancel();
      _hellos.remove(viewId);
    } else {
      say();
    }
  });
}

/// The players' messages, for every iframe: an answer stops its hello, an
/// end closes its window.
void _listen(web.MessageEvent event) {
  if (event.origin != youtubeEmbedOrigin) return;
  final data = event.data;
  if (data == null || !data.isA<JSString>()) return;
  final text = (data as JSString).toDart;
  final id = int.tryParse(youtubePlayerId(text) ?? '');
  if (id == null) return;
  _hellos.remove(id)?.cancel();
  if (youtubeEndedId(text) != null) _onEnded[id]?.call();
}

void _register() {
  if (_registered) return;
  _registered = true;
  web.window.addEventListener('message', _listen.toJS);
  ui_web.platformViewRegistry.registerViewFactory(_viewType, (
    int viewId, {
    Object? params,
  }) {
    final iframe = web.HTMLIFrameElement()
      ..src = youtubeEmbedUrl(
        params! as String,
        origin: web.window.location.origin,
      )
      ..allow = 'autoplay; encrypted-media; picture-in-picture';
    // The player's own links (the title, the logo, „Watch on YouTube“)
    // would open a tab over the kiosk: no popups, no navigation out.
    iframe.setAttribute(
      'sandbox',
      'allow-scripts allow-same-origin allow-presentation',
    );
    iframe.style
      ..border = 'none'
      ..width = '100%'
      ..height = '100%';
    iframe.addEventListener(
      'load',
      ((web.Event _) => _greet(viewId)).toJS,
    );
    _frames[viewId] = iframe;
    return iframe;
  });
}

/// The player on the web: an `<iframe>` with the embed. The engine keeps
/// every Flutter canvas at `pointer-events: none` and only the platform
/// view answers, so a dialog drawn over the iframe would be see-through to
/// YouTube and a drag crossing it would lose its pointer: [interactive]
/// false switches the iframe's own pointer events off. [onEnded] runs when
/// the player says its video has ended.
class KioskStreamView extends StatefulWidget {
  const KioskStreamView({
    super.key,
    required this.videoId,
    this.interactive = true,
    this.onEnded,
  });

  final String videoId;
  final bool interactive;
  final VoidCallback? onEnded;

  @override
  State<KioskStreamView> createState() => _KioskStreamViewState();
}

class _KioskStreamViewState extends State<KioskStreamView> {
  int? _viewId;

  @override
  void initState() {
    super.initState();
    _register();
  }

  void _apply() {
    if (_viewId case final id?) {
      _frames[id]?.style.pointerEvents = widget.interactive ? 'auto' : 'none';
    }
  }

  @override
  void didUpdateWidget(KioskStreamView old) {
    super.didUpdateWidget(old);
    if (old.interactive != widget.interactive) _apply();
  }

  @override
  void dispose() {
    if (_viewId case final id?) {
      _frames.remove(id);
      _onEnded.remove(id);
      _hellos.remove(id)?.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(
    viewType: _viewType,
    creationParams: widget.videoId,
    onPlatformViewCreated: (id) {
      _viewId = id;
      _onEnded[id] = () => widget.onEnded?.call();
      _apply();
    },
  );
}
