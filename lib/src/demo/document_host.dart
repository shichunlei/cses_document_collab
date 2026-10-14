import 'dart:async';

import 'package:cses_common/core/collections/objectid.dart';
import 'package:cses_common/observability/api/log.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/demo/common_cses_collab_gateway.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_account_login.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_demo_host.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_editor_media_upload_service.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// Demo composition root for package controllers and its owned Common socket.
///
/// Create with `DemoDocumentHost(session: session)`, await initialize, borrow
/// controller for the editor page, then await close before account switching.
/// Unlike the package, this host owns authentication, storage location and
/// foreground connection recovery. Late initialization is joined during close.
class DemoDocumentHost extends ChangeNotifier with WidgetsBindingObserver {
  /// [session] is the authenticated snapshot; null opens the local draft.
  DemoDocumentHost({this.session});

  /// Borrowed session; credentials never enter the package controller.
  final CsesAccountSession? session;
  final CsesDemoHost _socket = const CsesDemoHost();
  CollabController? _controller;
  Future<void>? _initialization;
  Future<void>? _closing;
  Future<bool>? _recovery;
  bool _disposed = false;
  bool _ownsConnection = false;
  String? _error;

  /// Borrow the document controller after host storage initialization.
  CollabController? get controller => _controller;

  /// Host initialization failure, separate from the controller's sync errors.
  String? get error => _error;

  /// Initialize once. Errors are logged and exposed while retaining the page.
  Future<void> initialize() => _initialization ??= _initialize();

  /// Choose the legacy SQLite location and assemble only public package APIs.
  Future<void> _initialize() async {
    try {
      final directory = await getApplicationSupportDirectory();
      if (_disposed) return;
      final path = '${directory.path}/cses_mobile_collab_demo/updates.sqlite3';
      final services = CollabHostServices(
        createId: () => ObjectId().toString(),
        onError: (message, error, stack, tag) =>
            Log.e(message, error: error, stackTrace: stack, tag: tag),
        mediaUpload: const CsesEditorMediaUploadService(),
      );
      final account = session;
      if (account == null) {
        _controller = CollabController.localDraft(
          databasePath: path,
          defaultCoverUrl:
              'https://gips0.baidu.com/it/u=4248708052,2809939788&fm=3028&app=3028&f=JPEG&fmt=auto?w=1280&h=720',
          services: services,
        );
      } else {
        _ownsConnection = true;
        await _socket.configure(account.settings);
        if (_disposed) return;
        final settings = account.settings;
        _controller = CollabController.cses(
          config: CollabDocumentConfig(
            documentId: settings.documentId,
            serverIdentity: settings.websocketUrl,
            companyId: settings.companyId,
            userId: settings.userId,
            userName: account.displayName,
            databasePath: path,
            editable: true,
          ),
          gateway: CommonCsesCollabGateway(),
          services: services,
        );
      }
      _controller!.addListener(_changed);
      _changed();
      await _controller!.initialize();
      if (_disposed) return;
      WidgetsBinding.instance.addObserver(this);
      if (_ownsConnection) await _socket.connect();
    } catch (error, stackTrace) {
      // Package initialization reports through the injected telemetry callback.
      // Only failures before a controller exists belong to this host boundary.
      if (_controller == null) {
        Log.e(
          'Demo 文档初始化失败',
          error: error,
          stackTrace: stackTrace,
          tag: 'DocCollabDemo',
        );
      }
      _error = '文档加载失败，请检查本地库或登录配置';
    } finally {
      _changed();
    }
  }

  /// Notify a live page; package callbacks cannot write a disposed host.
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Reconnect with the same authenticated context, then retry only document sync.
  Future<void> reconnect() async {
    if (_disposed || !_ownsConnection) return;
    try {
      if (await _recover() && !_disposed) await _controller?.retry();
    } catch (error, stackTrace) {
      Log.e(
        'Demo 重新连接失败',
        error: error,
        stackTrace: stackTrace,
        tag: 'DocCollabDemo',
      );
      _error = '连接恢复失败，请重试';
      _changed();
    }
  }

  /// Share a foreground/retry recovery task so teardown can await all socket work.
  /// Closing the host rejects new recoveries; existing work finishes before the
  /// socket is closed, preventing old-account recovery from racing new login.
  Future<bool> _recover() {
    if (_disposed) return Future<bool>.value(false);
    return _recovery ??= _socket.recover().whenComplete(() => _recovery = null);
  }

  /// Delegate [state] foreground events to the app-owned connection policy.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_resume());
  }

  /// Recover the socket without clearing terminal document/permission failures.
  Future<void> _resume() async {
    try {
      if (!_disposed && _ownsConnection && await _recover() && !_disposed) {
        _controller?.resync();
      }
    } catch (error, stackTrace) {
      Log.e(
        'Demo 前台恢复失败',
        error: error,
        stackTrace: stackTrace,
        tag: 'DocCollabDemo',
      );
    }
  }

  /// Wait for late initialization, document teardown and owned socket closure.
  Future<void> close() {
    dispose();
    return _closing!;
  }

  /// Invalidate callbacks immediately; asynchronous teardown is joined by close.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _closing = _shutdown();
    unawaited(_closing!);
    super.dispose();
  }

  /// Release the package before clearing the demo-owned authentication context.
  Future<void> _shutdown() async {
    try {
      await _initialization;
      _controller?.removeListener(_changed);
      await _controller?.close();
      // Recovery errors are reported by reconnect/_resume. Wait without logging
      // them twice, then close the socket under the old authentication context.
      await _recovery?.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    } finally {
      if (_ownsConnection) _socket.close();
    }
  }
}
