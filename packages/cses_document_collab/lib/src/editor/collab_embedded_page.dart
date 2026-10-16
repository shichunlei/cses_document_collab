import 'dart:async';

import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Resolves original HTTP(S) [url] to the desktop embed provider's frame URL.
/// Figma design URLs use its official embed endpoint; existing embed endpoints
/// pass through. Other sites, including Juejin, keep the original URL.
Uri collabFrameUrl(String url) {
  final uri = Uri.parse(url);
  if (const {'figma.com', 'www.figma.com'}.contains(uri.host) && uri.path != '/embed') {
    return Uri.https('www.figma.com', '/embed', {'embed_host': 'share', 'url': url});
  }
  return uri;
}

/// Owns one platform WebView surface; credentials and document APIs are not injected.
/// URL changes/retries invalidate old callbacks. Platform widget removal releases
/// the platform view; WebViewController has no public dispose operation.
///
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_embedded_page.dart';
/// import 'package:flutter/material.dart';
/// Widget frame() => const SizedBox(height: 240,
///   child: CollabEmbeddedPage(url: 'https://example.com'));
/// ```
class CollabEmbeddedPage extends StatefulWidget {
  /// Creates a frame for validated absolute HTTP(S) [url]. [key] controls widget
  /// identity/state reuse; this widget owns its controller and platform surface.
  const CollabEmbeddedPage({super.key, required this.url});

  /// Required original URL; changing it replaces the controller and invalidates callbacks.
  final String url;

  /// Creates local loading/failure state; platform resources belong to this view.
  @override
  State<CollabEmbeddedPage> createState() => _EmbeddedPageState();
}

/// Guards asynchronous configuration and callbacks with a request generation.
class _EmbeddedPageState extends State<CollabEmbeddedPage> {
  /// Controller currently installed in the platform widget, or null while loading.
  WebViewController? _controller;
  String? _error;
  int _progress = 0;
  int _generation = 0;

  /// Configures the first view on mounting; failures are rendered locally.
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Restarts only when borrowed [oldWidget] references a different source URL.
  @override
  void didUpdateWidget(covariant CollabEmbeddedPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url) unawaited(_load());
  }

  /// Configures/loads a fresh controller; stale requests stop after each await.
  /// All configuration and loading exceptions become retryable local failures.
  /// Navigation is limited to HTTP(S), with no editor/native JavaScript bridge.
  Future<void> _load() async {
    final generation = ++_generation;
    bool current() => mounted && generation == _generation;
    _controller = null;
    _progress = 0;
    _error = null;
    if (WebViewPlatform.instance == null) {
      _error = '当前设备不支持嵌入浏览';
      if (mounted) setState(() {});
      return;
    }
    try {
      final controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (!current()) return;
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (current()) setState(() => _progress = progress);
          },
          onPageStarted: (_) {
            if (current()) {
              setState(() {
                _error = null;
                _progress = 0;
              });
            }
          },
          onPageFinished: (_) {
            if (current()) setState(() => _progress = 100);
          },
          onWebResourceError: (error) {
            if (current() && error.isForMainFrame != false) {
              setState(() => _error = '网页暂时无法加载');
            }
          },
          onNavigationRequest: (request) =>
              isCollabResourceUrl('embed', request.url) ? NavigationDecision.navigate : NavigationDecision.prevent,
        ),
      );
      if (!current()) return;
      await controller.loadRequest(collabFrameUrl(widget.url));
      if (current()) setState(() => _controller = controller);
    } catch (_) {
      if (current()) setState(() => _error = '网页暂时无法加载');
    }
  }

  /// Invalidates pending work before Flutter removes and releases the platform view.
  @override
  void dispose() {
    _generation++;
    _controller = null;
    super.dispose();
  }

  /// Returns a bounded frame/error surface in [context]; failures retain a retry
  /// action while the enclosing block retains view switching and original URL.
  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return ColoredBox(
        color: const Color(0xFFF8FAFC),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!),
              TextButton(
                onPressed: () {
                  setState(() {});
                  unawaited(_load());
                },
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    return Stack(
      children: [
        if (_controller != null)
          Positioned.fill(
            child: WebViewWidget(
              key: ValueKey(_controller),
              controller: _controller!,
              gestureRecognizers: {Factory<EagerGestureRecognizer>(() => EagerGestureRecognizer())},
            ),
          ),
        if (_progress < 100) LinearProgressIndicator(value: _progress == 0 ? null : _progress / 100, minHeight: 2),
      ],
    );
  }
}
