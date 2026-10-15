import 'dart:async';

import 'package:cses_common/core/collections/objectid.dart';
import 'package:cses_common/flutter/feedback/toast_util.dart';
import 'package:cses_common/observability/api/log.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/demo/common_cses_collab_gateway.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_account_login.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_demo_host.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_editor_media_upload_service.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'cses_document_metadata_service.dart';
import 'cses_meeting_card_service.dart';
import 'cses_mention_directory.dart';
import 'meeting_reference_picker.dart';
import 'mention_avatar.dart';
import 'mention_picker.dart';

/// Demo composition root for package controllers and its owned Common socket.
///
/// Create after Common login, await initialize, borrow
/// controller for the editor page, then await close before account switching.
/// This host reads Common identity once into the package's document config,
/// owns the storage location and foreground recovery, and clears Common login
/// after document teardown. Late initialization is joined during close.
class DemoDocumentHost extends ChangeNotifier with WidgetsBindingObserver {
  /// Uses Common login; [localDraft] opens an offline draft for preview or tests.
  DemoDocumentHost({this.localDraft = false});

  /// Explicit document mode; credentials never enter the package controller.
  final bool localDraft;
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

  /// 初始化存储并注入公开包服务；头像、人员与会议引用页面由宿主创建，人员服务绑定当前账号/企业，草稿不启用选人。
  /// 等待原生初始化与宿主连接，关闭期间迟到结果不安装页面监听。
  Future<void> _initialize() async {
    // 登录已在 Common 注入；即使本地存储初始化失败，退出也须清理该登录。
    _ownsConnection = !localDraft;
    try {
      final directory = await getApplicationSupportDirectory();
      if (_disposed) return;
      final path = '${directory.path}/cses_mobile_collab_demo/updates.sqlite3';
      final mentionDirectory = localDraft ? null : CsesMentionDirectory();
      final services = CollabHostServices(
        createId: () => ObjectId().toString(),
        onError: (message, error, stack, tag) =>
            Log.e(message, error: error, stackTrace: stack, tag: tag),
        mediaUpload: const CsesEditorMediaUploadService(),
        documentMetadata: localDraft ? null : CsesDocumentMetadataService(),
        mentionAvatarBuilder: buildDemoMentionAvatar,
        pickMentionUser: mentionDirectory == null
            ? null
            : (context, {required keyword, required canEdit}) =>
                  showDemoMentionPicker(
                    context,
                    directory: mentionDirectory,
                    keyword: keyword,
                    canEdit: canEdit,
                  ),
        pickMeetingReference: showDemoMeetingReferencePicker,
        loadMeetingCard: localDraft ? null : CsesMeetingCardService().load,
        onMeetingCardTap: (String meetingId, String title, String number) {
          Log.d(meetingId.toString());
          showToast(text: "打开会议页面");
        },
        onMentionTap: (CollabMentionTap mention) {
          Log.json(mention.toJson());
          showToast(text: "点击了${mention.name}");
        },
      );
      if (localDraft) {
        _controller = CollabController.localDraft(
          databasePath: path,
          services: services,
        );
      } else {
        // 身份和服务端地址只在这里从 Common 读取并注入不可变文档配置。
        // 包自行计算缓存分区；cookie 与物理连接仍由 Common 持有，不进入文档配置。
        // 切换用户/企业须先释放旧控制器，再用新的 Common 上下文创建控制器。
        final user = User();
        _controller = CollabController.cses(
          config: CollabDocumentConfig(
            documentId: csesDemoDocumentId,
            serverIdentity: ctx.websocketHost ?? '',
            companyId: user.companyId,
            userId: user.userId ?? '',
            userName: user.name.isNotEmpty ? user.name : user.userName,
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
      if (await _recover() && !_disposed) {
        await _controller?.retry();
        await _controller?.header?.refresh();
      }
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
        await _controller?.header?.refresh();
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
