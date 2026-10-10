import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../../domain/youtube.dart';

/// The player in the app: a WebView with the embed as an iframe of a host
/// page that has an origin (see [kioskStreamHostOrigin]). [interactive] is
/// nothing here — Flutter hit-tests the view itself, and a modal barrier
/// covers it. [onEnded] runs when the host page hands over the player's
/// „ended“ ([kioskStreamChannel]).
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
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel(
        kioskStreamChannel,
        onMessageReceived: (message) {
          if (youtubeEndedId(message.message) != null) widget.onEnded?.call();
        },
      )
      // The embed's title, logo and „Watch on YouTube“ are links out of
      // the kiosk; a popup is loaded into this very view unless refused.
      // The host page is the only top-level page this view ever shows.
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              request.isMainFrame &&
                  !request.url.startsWith(kioskStreamHostOrigin)
              ? NavigationDecision.prevent
              : NavigationDecision.navigate,
        ),
      );
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      // Muted autoplay without a tap, like a browser allows.
      platform.setMediaPlaybackRequiresUserGesture(false);
    }
    _controller.loadHtmlString(
      kioskStreamHostPage(
        youtubeEmbedUrl(widget.videoId, origin: kioskStreamHostOrigin),
      ),
      baseUrl: kioskStreamHostOrigin,
    );
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
