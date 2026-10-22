import 'dart:async';
import 'dart:io';

import 'package:cses_common/core/collections/objectid.dart';
import 'package:cses_common/flutter/feedback/toast_util.dart';
import 'package:cses_common/observability/api/log.dart';
import 'package:cses_common/runtime/config/config.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/demo/common_cses_collab_gateway.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_account_login.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_demo_host.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_editor_media_upload_service.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/cses_document_creation_service.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_coordinator.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_operation.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_store.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_list_page.dart';

import 'cses_document_metadata_service.dart';
import 'cses_kr_service.dart';
import 'cses_meeting_card_service.dart';
import 'cses_mention_directory.dart';
import 'cses_task_card_service.dart';
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
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/document_host.dart';
/// Future<void> openAfterLogin() async {
///   final host = DemoDocumentHost();
///   await host.initialize();
///   // 页面借用host.controller；创建入口使用host.creation。
///   await host.close(); // 移除借用视图后关闭账号与文档资源。
/// }
/// ```
class DemoDocumentHost extends ChangeNotifier with WidgetsBindingObserver {
  /// Uses Common login; [localDraft] opens an offline draft for preview or tests.
  /// [initialDocumentId]显式指定正式根，null优先恢复最近创建文档，再回落测试文档。
  DemoDocumentHost({this.localDraft = false, this.initialDocumentId});

  /// Explicit document mode; credentials never enter the package controller.
  final bool localDraft;

  /// 调用方指定的正式文档；草稿模式忽略，null使用本账号最近文档。
  final String? initialDocumentId;
  final CsesDemoHost _socket = const CsesDemoHost();
  CollabController? _controller;
  Future<void>? _initialization;
  Future<void>? _closing;
  Future<bool>? _recovery;

  /// 宿主持有的权限刷新请求；文档切换和账号关闭等待它结束。
  Future<void>? _permissionRefresh;
  bool _disposed = false;
  bool _ownsConnection = false;
  String? _error;

  /// 初始化失败后仍观察前台恢复；关闭时只注销一次。
  bool _observingLifecycle = false;

  /// 首次恢复结束后才允许新建，避免与默认文档打开争用单Doc引擎。
  bool _ready = false;
  late String _databasePath;
  late CollabHostServices _services;
  CsesDocumentCreationService? _creationApi;

  /// 宿主唯一持有的账号创建协调器，关闭先等待其在途请求，再关闭文档和连接。
  DocumentCreationCoordinator? _creation;

  /// 当前账号的新建协调器；初始恢复完成前为null，由本宿主释放。
  DocumentCreationCoordinator? get creation => _ready ? _creation : null;

  /// 读取真实新建位置；身份检查由绑定当前账号的业务适配器执行。
  Future<List<DocumentCreationTarget>> loadCreationTargets() =>
      _creationApi?.loadTargets() ?? Future.error(StateError('新建服务尚未就绪'));

  /// 读取[target]的第[pageNumber]页文档；页码从1开始，鉴权仍绑定本宿主账号。
  /// 服务未就绪时返回失败，不把不可用服务伪装为空空间。
  Future<DocumentListPage> loadCreationDocuments(DocumentCreationTarget target, int pageNumber) =>
      _creationApi?.loadDocuments(target, pageNumber) ?? Future.error(StateError('新建服务尚未就绪'));

  /// Borrow the document controller after host storage initialization.
  CollabController? get controller => _controller;

  /// Host initialization failure, separate from the controller's sync errors.
  String? get error => _error;

  /// 初始化文档并共享在途任务；创建控制器前失败时清理临时资源，允许再次调用。
  /// 关闭后不重新打开资源；错误由error公开给页面，缓存恢复不等待权限HTTP。
  Future<void> initialize() {
    if (_disposed) return Future<void>.error(StateError('文档宿主已关闭'));
    return _initialization ??= _initialize();
  }

  /// 初始化存储并注入公开包服务；头像、人员与会议引用页面由宿主创建，会议/任务详情绑定账号会话，草稿不启用业务加载。
  /// 等待原生初始化与宿主连接，关闭期间迟到结果不安装页面监听。
  /// 段落链接按Common环境选择桌面同源文档域名，并携带正式文档ID及blockId。
  /// 文末点赞回调返回演示成员快照，评论回调返回当前数量；图片点击接收链接并演示提示，不进行业务持久化。
  Future<void> _initialize() async {
    _ready = false;
    // 登录已在 Common 注入；即使本地存储初始化失败，退出也须清理该登录。
    _ownsConnection = !localDraft;
    try {
      final directory = await getApplicationSupportDirectory();
      if (_disposed) return;
      final path = p.join(directory.path, 'cses_mobile_collab_demo', 'updates.sqlite3');
      _databasePath = path;
      final mentionDirectory = localDraft ? null : CsesMentionDirectory();
      final metadata = localDraft ? null : CsesDocumentMetadataService();
      final services = CollabHostServices(
        canUnlockBlock: metadata?.canUnlockBlock,
        buildParagraphLink: localDraft
            ? null
            : (documentId, blockId) => Uri(
                scheme: 'http',
                host: Config().envType.docHost ?? (throw StateError('当前环境未配置文档域名')),
                pathSegments: ['doc', documentId],
                queryParameters: {'blockId': blockId},
              ).toString(),
        showDocumentFeedback: true,
        onDocumentLike: (documentId, likes) {
          final user = User();
          final userId = localDraft ? 'demo-user' : (user.userId ?? '');
          final name = localDraft ? '演示用户' : (user.name.isNotEmpty ? user.name : user.userName);
          showToast(text: likes.isLiked ? '取消点赞：$documentId' : '点赞文档：$documentId');
          return CollabDocumentLikes(
            isLiked: !likes.isLiked,
            members: [
              ...likes.members.where((member) => member.userId != userId),
              if (!likes.isLiked) CollabDocumentLikeMember(userId: userId, name: name),
            ],
          );
        },
        onDocumentComment: (documentId, commentCount) {
          showToast(text: '评论全文：$documentId，当前$commentCount条');
          return commentCount;
        },
        createId: () => ObjectId().toString(),
        onError: (message, error, stack, tag) =>
            Log.e(message, error: error, stackTrace: stack, tag: tag),
        mediaUpload: const CsesEditorMediaUploadService(),
        documentMetadata: metadata,
        mentionAvatarBuilder: buildDemoMentionAvatar,
        pickMentionUser: mentionDirectory == null
            ? null
            : (context, {required keyword, required canEdit}) => showDemoMentionPicker(
                context,
                directory: mentionDirectory,
                keyword: keyword,
                canEdit: canEdit,
              ),
        pickMeetingReference: showDemoMeetingReferencePicker,
        loadMeetingCard: localDraft ? null : CsesMeetingCardService().load,
        loadTaskCard: localDraft ? null : CsesTaskCardService().load,
        kr: localDraft ? null : CsesKrService(),
        krRankIcons: (first: Text('🥇'), second: Text('🥈'), third: Text('🥉')),
        onMeetingCardTap: (String meetingId, String title, String number) {
          Log.d(meetingId.toString());
          showToast(text: "打开会议页面");
        },
        onImageTap: (String url) {
          Log.d('图片点击：$url');
          showToast(text: '点击了图片');
        },
        onMentionTap: (CollabMentionTap mention) {
          Log.json(mention.toJson());
          showToast(text: "点击了${mention.name}");
        },
      );
      _services = services;
      if (localDraft) {
        _controller = CollabController.localDraft(databasePath: path, services: services);
      } else {
        final api = _creationApi = CsesDocumentCreationService();
        _creation = DocumentCreationCoordinator(
          api: api,
          store: FileDocumentCreationStore(
            directory: Directory(p.join(directory.path, 'cses_mobile_collab_demo', 'creation')),
            scope: api.scope,
          ),
          createId: () => ObjectId().toString(),
          closeDocument: _closeDocument,
          prepare: (operation) => DocumentBootstrapper.prepareBlank(
            config: _formalConfig(operation.documentId!, editable: true),
            operationId: operation.operationId,
            paragraphId: operation.paragraphId,
            createdAt: DateTime.fromMillisecondsSinceEpoch(operation.createdAt),
          ),
          openDocument: _openFormalDocument,
        );
        _creation!.addListener(_changed);
        await _creation!.restore();
        if (_disposed) return;
        final operation = _creation!.operation;
        await _openFormalDocument(
          initialDocumentId ??
              (operation?.stage == DocumentCreationStage.completed
                  ? operation!.documentId!
                  : csesDemoDocumentId),
        );
        if (_disposed) return;
        api.checkSession();
        await _socket.connect();
      }
      if (localDraft) {
        _controller!.addListener(_changed);
        _changed();
        await _controller!.initialize();
      }
      if (_disposed) return;
    } catch (error, stackTrace) {
      // Package initialization reports through the injected telemetry callback.
      // Only failures before a controller exists belong to this host boundary.
      if (_controller == null) {
        Log.e('Demo 文档初始化失败', error: error, stackTrace: stackTrace, tag: 'DocCollabDemo');
        _creation?.removeListener(_changed);
        await _creation?.close();
        _creation = null;
        _creationApi = null;
        _initialization = null;
      }
      _error = '文档加载失败，请检查本地库或登录配置';
    } finally {
      if (!_disposed && !_observingLifecycle) {
        WidgetsBinding.instance.addObserver(this);
        _observingLifecycle = true;
      }
      _ready = true;
      _changed();
    }
  }

  /// 为正式[documentId]绑定当前账号和[editable]授权；不持有凭证或连接。
  CollabDocumentConfig _formalConfig(String documentId, {required bool editable}) {
    _creationApi!.checkSession();
    final user = User();
    return CollabDocumentConfig(
      documentId: documentId,
      serverIdentity: ctx.websocketHost ?? '',
      companyId: user.companyId,
      userId: user.userId ?? '',
      userName: user.name.isNotEmpty ? user.name : user.userName,
      databasePath: _databasePath,
      editable: editable,
    );
  }

  /// 先以只读恢复[documentId]的SQLite正文，再独立读取权限；旧控制器必须先释放。
  /// 权限传输失败保留可读缓存，明确授权后才能编辑或补传。权限任务由宿主持有，
  /// 文档切换和关闭等待它结束，迟到结果不应用到其他文档。
  Future<void> _openFormalDocument(String documentId) async {
    if (_disposed) throw StateError('文档宿主已关闭');
    if (_controller != null) throw StateError('请先关闭旧文档');
    final controller = CollabController.cses(
      config: _formalConfig(documentId, editable: false),
      gateway: CommonCsesCollabGateway(),
      services: _services,
    );
    _controller = controller;
    controller.addListener(_changed);
    await controller.initialize();
    if (_disposed) return;
    _error = null;
    _changed();
    unawaited(_refreshDocumentPermissions());
  }

  /// 仅释放当前文档并等待旧恢复任务，不关闭账号主连接；新建准备随后取得原生所有权。
  Future<void> _closeDocument() async {
    final controller = _controller;
    _controller = null;
    controller?.removeListener(_changed);
    _changed();
    await _permissionRefresh?.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    await controller?.close();
    await _recovery?.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }

  /// Notify a live page; package callbacks cannot write a disposed host.
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// 先重试失败的本地打开并刷新权限，再恢复主连接及当前文档握手。
  /// HTTPS权限恢复不依赖WebSocket就绪；初始权限失败时继续使用同一缓存控制器。
  Future<void> reconnect() async {
    if (_disposed || _creation?.busy == true) return;
    try {
      if (_controller == null) await initialize();
      if (_disposed || _controller == null || !_ownsConnection) return;
      final controller = _controller!;
      await _refreshDocumentPermissions();
      if (_disposed || !identical(controller, _controller) || _creation?.busy == true) {
        return;
      }
      if (await _recover() && !_disposed && identical(controller, _controller)) {
        await controller.retry();
      }
    } catch (error, stackTrace) {
      Log.e('Demo 重新连接失败', error: error, stackTrace: stackTrace, tag: 'DocCollabDemo');
      _error = '连接恢复失败，请重试';
      _changed();
    }
  }

  /// Share a foreground/retry recovery task so teardown can await all socket work.
  /// Closing the host rejects new recoveries; existing work finishes before the
  /// socket is closed, preventing old-account recovery from racing new login.
  Future<bool> _recover() {
    if (_disposed) return Future<bool>.value(false);
    _creationApi?.checkSession();
    return _recovery ??= _socket.recover().whenComplete(() => _recovery = null);
  }

  /// Delegate [state] foreground events to the app-owned connection policy.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_resume());
  }

  /// 前台先恢复本地打开和权限，再恢复连接；失败不会清除缓存或绕过终止错误。
  Future<void> _resume() async {
    try {
      if (_disposed || _creation?.busy == true || !_ownsConnection) return;
      if (_controller == null) await initialize();
      if (_disposed || _controller == null) return;
      final controller = _controller!;
      await _refreshDocumentPermissions();
      if (_disposed || !identical(controller, _controller) || _creation?.busy == true) {
        return;
      }
      if (await _recover() && !_disposed && identical(controller, _controller)) {
        controller.resync();
      }
    } catch (error, stackTrace) {
      Log.e('Demo 前台恢复失败', error: error, stackTrace: stackTrace, tag: 'DocCollabDemo');
    }
  }

  /// 合并当前文档权限刷新；明确拒绝立即撤权，传输失败保留已有授权或初始只读。
  /// 切换期间的结果不应用到新控制器，关闭等待在途请求，不保留旧账号授权。
  /// 失败在此记录并展示，不使已恢复的正文初始化失败或产生未处理Future。
  Future<void> _refreshDocumentPermissions() => _permissionRefresh ??= _readDocumentPermissions()
      .then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          Log.e('Demo 文档权限读取失败', error: error, stackTrace: stackTrace, tag: 'DocCollabDemo');
          if (_disposed) return;
          _error = _controller?.canEdit == true ? '权限暂时无法刷新，保留现有授权' : '权限暂未确认，已恢复只读缓存，请重试';
          _changed();
        },
      )
      .whenComplete(() => _permissionRefresh = null);

  /// 读取当前身份下的编辑授权及头部，只向仍活动的同一文档回写。
  /// 请求期间身份变化同样立即撤权，不将传输故障当作沿用旧账号授权的依据。
  Future<void> _readDocumentPermissions() async {
    final controller = _controller;
    if (_disposed || controller == null || _creationApi == null) return;
    bool editable;
    try {
      _creationApi!.checkSession();
    } catch (_) {
      await controller.setEditable(false);
      rethrow;
    }
    try {
      editable = await _creationApi!.editableFor(controller.documentId);
    } on DocumentCreationRejected {
      editable = false;
    } catch (_) {
      if (!_disposed && identical(controller, _controller)) {
        try {
          _creationApi!.checkSession();
        } catch (_) {
          await controller.setEditable(false);
        }
      }
      rethrow;
    }
    if (_disposed || !identical(controller, _controller)) return;
    await controller.setEditable(editable);
    if (!_disposed && identical(controller, _controller)) {
      _error = null;
      _changed();
      await controller.header?.refresh();
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
    if (_observingLifecycle) WidgetsBinding.instance.removeObserver(this);
    _closing = _shutdown();
    unawaited(_closing!);
    super.dispose();
  }

  /// Release the package before clearing the demo-owned authentication context.
  Future<void> _shutdown() async {
    try {
      await _initialization;
      _creation?.removeListener(_changed);
      await _creation?.close();
      await _permissionRefresh?.then<void>((_) {}, onError: (Object _, StackTrace _) {});
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
