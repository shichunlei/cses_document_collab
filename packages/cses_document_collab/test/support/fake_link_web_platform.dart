import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// Test platform records requests; it creates no operating-system view or network client.
class FakeLinkWebPlatform extends WebViewPlatform {
  /// Requests actually loaded after controller setup completes.
  final loads = <Uri>[];

  /// Controllers created by this test platform; owned by the test case.
  final controllers = <_Controller>[];

  /// Optional setup gate; null completes JavaScript configuration immediately.
  Completer<void>? scriptGate;

  /// Creates a recorded controller using borrowed creation [params].
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = _Controller(params, loads, scriptGate?.future);
    controllers.add(controller);
    return controller;
  }

  /// Returns an in-memory callback delegate for [params].
  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _Navigation(params);

  /// Returns a native-view substitute using borrowed [params].
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _WebWidget(params);
}

/// Controller fake with an optional async initialization barrier.
class _Controller extends PlatformWebViewController {
  /// Binds [params], shared request [loads], and optional initialization [gate].
  _Controller(super.params, this.loads, this.gate) : super.implementation();
  final List<Uri> loads;
  final Future<void>? gate;
  _Navigation? delegate;

  /// Waits for the fixture gate when configuring JavaScript [mode].
  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {
    await gate;
  }

  /// Borrows [delegate] for test-driven navigation and error callbacks.
  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate delegate,
  ) async {
    this.delegate = delegate as _Navigation;
  }

  /// Records [params] and synchronously reports a completed page load.
  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loads.add(params.uri);
    delegate?.progress?.call(100);
  }
}

/// In-memory delegate exposes callbacks to lifecycle tests.
class _Navigation extends PlatformNavigationDelegate {
  /// Creates a test callback holder for [params].
  _Navigation(super.params) : super.implementation();
  ProgressCallback? progress;
  NavigationRequestCallback? navigation;
  WebResourceErrorCallback? error;

  /// Stores progress [callback] without scheduling work.
  @override
  Future<void> setOnProgress(ProgressCallback callback) async {
    progress = callback;
  }

  /// Stores navigation [callback] for protocol validation assertions.
  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async {
    navigation = callback;
  }

  /// Stores error [callback] to distinguish main-frame and subresource failures.
  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async {
    error = callback;
  }

  /// Accepts started [callback]; load completion is simulated by progress.
  @override
  Future<void> setOnPageStarted(PageEventCallback callback) async {}

  /// Accepts finished [callback]; load completion is simulated by progress.
  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async {}
}

/// Lightweight replacement for an operating-system WebView widget.
class _WebWidget extends PlatformWebViewWidget {
  /// Borrows the platform widget creation [params].
  _WebWidget(super.params) : super.implementation();

  /// Returns deterministic frame content in [context].
  @override
  Widget build(BuildContext context) => const Center(child: Text('内嵌网页'));
}
