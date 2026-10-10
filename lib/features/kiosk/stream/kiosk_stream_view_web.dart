import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import '../../../domain/youtube.dart';

const _viewType = 'rezervator-kiosk-stream';

/// The iframes alive, by platform view id — kept so [KioskStreamView]
/// can switch their pointer events.
final _frames = <int, web.HTMLIFrameElement>{};
var _registered = false;

void _register() {
  if (_registered) return;
  _registered = true;
  ui_web.platformViewRegistry.registerViewFactory(_viewType, (
    int viewId, {
    Object? params,
  }) {
    final iframe = web.HTMLIFrameElement()
      ..src = youtubeEmbedUrl(params! as String)
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
    _frames[viewId] = iframe;
    return iframe;
  });
}

/// The player on the web: an `<iframe>` with the embed. The engine keeps
/// every Flutter canvas at `pointer-events: none` and only the platform
/// view answers, so a dialog drawn over the iframe would be see-through to
/// YouTube and a drag crossing it would lose its pointer: [interactive]
/// false switches the iframe's own pointer events off.
class KioskStreamView extends StatefulWidget {
  const KioskStreamView({
    super.key,
    required this.videoId,
    this.interactive = true,
  });

  final String videoId;
  final bool interactive;

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
    _frames.remove(_viewId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(
    viewType: _viewType,
    creationParams: widget.videoId,
    onPlatformViewCreated: (id) {
      _viewId = id;
      _apply();
    },
  );
}
