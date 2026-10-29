import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_native_selection.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_links.dart';
import 'package:cses_document_collab/src/editor/core/document_editor_controller.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/model/collab_block_lock.dart';
import 'package:cses_document_collab/src/model/collab_code.dart';
import 'package:cses_document_collab/src/model/collab_document_config.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/model/collab_image.dart';
import 'package:cses_document_collab/src/model/collab_ordered.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as rust;
import 'package:cses_document_collab/src/native/api/collab/history.dart' as native_history;
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/sync/cses_collab_gateway.dart';
import 'package:cses_document_collab/src/sync/cses_doc_collaboration_session.dart';
import 'package:flutter/foundation.dart';

import 'document_feedback_controller.dart';
import 'document_metadata_controller.dart';

/// 本地加载、主连接握手及协同会话映射出的展示状态；online 不表示数据库落库。
enum ConnectionStatus { starting, connecting, online, offline, error }

/// Owns one native document, local cache and editor; borrows the host gateway.
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final collab = CollabController.localDraft(databasePath: '/host/updates.sqlite');
/// await collab.initialize();
/// final page = CollaborativeEditorPage(collab: collab);
/// // After removing page, close before opening another native document.
/// await collab.close();
/// ```
class CollabController extends ChangeNotifier {
  /// Create a formal document with [config], a borrowed [gateway] and [services].
  /// Initialization performs no login and never creates or closes a socket.
  CollabController.cses({
    required CollabDocumentConfig config,
    required CsesCollabGateway gateway,
    CollabHostServices services = const CollabHostServices(),
  }) : this._(config, gateway, services);

  /// Create a body-only draft in [databasePath] with stable [documentId] and
  /// borrowed [services]. No online session or business header is started.
  CollabController.localDraft({
    required String databasePath,
    String documentId = 'demo-room',
    CollabHostServices services = const CollabHostServices(),
  }) : this._(CollabDocumentConfig.localDraft(databasePath: databasePath, documentId: documentId), null, services);

  /// Store [config], [gateway] and [services]; native ownership begins on initialize.
  /// Local transactions remain paused until initialization establishes access.
  /// 正式文档按宿主配置绑定段落链接，绑定先于编辑器释放；草稿不创建可分享链接。
  CollabController._(this.config, this._gateway, this._services) : _editable = config.editable {
    header = config.isFormal && _services.documentMetadata != null
        ? DocumentMetadataController(
            documentId: config.documentId,
            service: _services.documentMetadata!,
            canEdit: () => !_disposed && _editable,
            services: _services,
          )
        : null;
    header?.addListener(_notify);
    feedback = DocumentFeedbackController(documentId: config.documentId, services: _services);
    editor = DocumentEditorController(commandContext: EditorCommandContext(services: _services));
    _editorAdapter = AppFlowyBlockEditorAdapter(
      editing: editor,
      onLocalBlocksChanged: _applyEditorBlocks,
      onTransactionPreparing: _captureHistoryTransaction,
    );
    editorState.selectionNotifier.addListener(_captureLiveSelection);
    final linkBuilder = _services.buildParagraphLink;
    _paragraphLinks = config.isFormal && linkBuilder != null
        ? CollabParagraphLinks(editor: editorState, documentId: config.documentId, buildLink: linkBuilder)
        : null;
    _blockLocks = CollabBlockLocks(
      editor: editorState,
      userId: config.userId,
      canUnlock: _canUnlockBlock,
      commit: _commitBlockLock,
    );
    _syncLocalTransactionPause();
  }

  /// 本控制器拥有的独立编辑会话，数据绑定和页面只借用；投影结束后释放。
  late final DocumentEditorController editor;

  /// 控制器拥有的正式文档链接绑定；未配置宿主构造器或草稿时为null。
  late final CollabParagraphLinks? _paragraphLinks;

  /// 本控制器拥有的块权限投影；页面借用，close时早于编辑器释放。
  late final CollabBlockLocks _blockLocks;

  /// 读取[blockId]当前锁状态；未投影的新块暂按未锁处理，写入仍经过原生预检。
  CollabBlockLockState blockLock(String blockId) => _blockLocks.state(blockId);

  /// 将[blockId]设为[locked]；仅正式文档、有编辑权限且有效身份可操作。
  /// Future在锁字段落盘、安装投影和提交本地同步增量后完成，不代表服务端ACK。
  Future<void> setBlockLocked(String blockId, bool locked) =>
      _commitBlockLock(blockId, locked, _blockLocks.state(blockId));

  /// 查询宿主是否额外允许解开借用[state]；异常拒绝并记录，不默认提升权限。
  bool _canUnlockBlock(CollabBlockLockState state) {
    if (state.ownerId == null) return false;
    try {
      return _services.canUnlockBlock?.call(
            CollabBlockUnlockContext(
              documentId: documentId,
              blockId: state.blockId,
              currentUserId: config.userId,
              ownerId: state.ownerId!,
              template: state.template,
            ),
          ) ??
          false;
    } catch (error, stack) {
      _services.report('块解锁授权失败', error, stack, 'DocCollab');
      return false;
    }
  }

  /// 用最新原生状态核对[id]、[expected]及[locked]，只写锁字段；失败不改正文。
  Future<void> _commitBlockLock(String id, bool locked, CollabBlockLockState expected) async {
    if (!config.isFormal || !canEdit || !editorState.editable) throw StateError('当前文档不可操作锁');
    _syncBlockLocks();
    final current = _blockLocks.state(id);
    if (current != expected || !_blockLocks.canToggle(id)) throw StateError('锁状态或权限已更新，请重新选择');
    final result = rust.setBlockLock(
      blockId: id,
      locked: locked,
      userId: config.userId,
      grant: _canUnlockBlock(current),
      expectedOwner: current.explicit ? current.ownerId : null,
      expectedTemplate: current.explicit && current.template,
    );
    _lastBlocks = List.unmodifiable(result.blocks);
    _syncBlockLocks();
    _session?.sendLocalUpdate(result.v1Update);
    await _queueProjection();
    if (!_disposed) _notify();
  }

  /// 即使正文快照相等也从完整块图刷新权限，确保远端仅改锁时立即生效。
  void _syncBlockLocks() {
    _blockLocks.update(
      rust.currentBlockLocks().map(
        (value) => CollabBlockLockState(
          blockId: value.blockId,
          sourceId: value.sourceId,
          ownerId: value.ownerId,
          template: value.template,
          containsLock: value.containsLock,
        ),
      ),
    );
  }

  /// Immutable host identity and storage contract; contains no login credentials.
  final CollabDocumentConfig config;

  /// 正式业务头部，独立于原生正文；草稿或宿主未注入服务时为 null。
  late final DocumentMetadataController? header;

  /// 本控制器拥有的文末业务状态；不属于正文，close时等待并释放。
  late final DocumentFeedbackController feedback;
  final CsesCollabGateway? _gateway;
  final CollabHostServices _services;

  /// 当前文档借用的宿主能力与展示配置；资源始终由宿主持有。
  CollabHostServices get hostServices => _services;
  bool _editable;
  Future<void>? _initializationTask;
  Future<void> _accessTransition = Future<void>.value();
  late final AppFlowyBlockEditorAdapter _editorAdapter;
  CsesDocCollaborationSession? _session;
  Future<void> _projection = Future<void>.value();
  List<rust.CollabBlock> _lastBlocks = const [];
  String? _error;
  String? _readOnlyReason;
  String _lastProtocolEvent = 'not-started';
  String _sharedTypeName = 'cses_mobile_block_order';
  int _persistedUpdateCount = 0;
  int _remoteEditorCount = 0;
  ConnectionStatus _status = ConnectionStatus.starting;
  bool _initialized = false;
  bool _initializing = false;
  bool _busy = false;
  bool _disposed = false;

  /// Last published document capability, excluding the page's preview mode.
  /// Only real capability transitions update headless editor permissions;
  /// ordinary projections must preserve preview and in-flight edit sessions.
  bool _publishedCanEdit = false;

  /// Native history is session-local; UI never replays a second path stack.
  native_history.DocumentHistoryState _historyState = const native_history.DocumentHistoryState(
    undoDepth: 0,
    redoDepth: 0,
  );

  /// True after this owner has configured history on its current native Doc.
  bool _nativeHistoryReady = false;

  /// Suspends new input while an undo/redo awaits projection and selection replay.
  bool _historyExecuting = false;

  /// Number of serialized projections still borrowing this owner's editor.
  int _projectionPending = 0;

  /// Shared in-flight history operation; shutdown/cache reset await its completion.
  Future<void>? _historyTask;

  /// Borrowed transaction whose stable pre-edit selection belongs to the next write.
  Transaction? _historyTransaction;

  /// Endpoints captured before the transaction can delete or replace their nodes.
  native_history.HistorySelection? _beforeHistorySelection;

  /// Personal relative selection token, scoped to the current open native Doc.
  String? _liveSelectionBookmark;

  /// 当前控制器的异步释放任务；切换账号前等待它，避免旧宿主关闭新连接。
  Future<void>? _shutdownTask;

  /// 当前线上 docId，未连接时为本地草稿标识。
  String get documentId => config.documentId;

  /// 当前稳定失败文案，不含输入凭证。
  String? get error => _error;

  /// 最近协议阶段，用于实验观察，不是保存回执。
  String get lastProtocolEvent => _lastProtocolEvent;

  /// 当前模型根名称；本地草稿为 Demo 块顺序，CSES 正式文档为 blocks。
  String get sharedTypeName => _sharedTypeName;

  /// Rust 根据当前根、未支持结构和修订计算的整篇只读原因；null 表示结构可编辑。
  /// 此值不代表服务端业务权限，网络断开后仍保留已加载模型的编辑能力。
  String? get readOnlyReason => !_editable ? '宿主权限为只读' : _readOnlyReason;

  /// 当前可提交本地编辑；还须持有原生文档，未加载、切换、只读或协同错误时返回false。
  bool get canEdit =>
      !_disposed &&
      initialized &&
      CollabRuntime.owns(this) &&
      !busy &&
      _editable &&
      _readOnlyReason == null &&
      _status != ConnectionStatus.error;

  /// Whether the native binding is ready for another local transaction.
  /// Page preview/import additionally requires [editorState] to be editable.
  /// History and projections pause transactions without changing [canEdit]'s
  /// document permission or forcing a preview/keyboard transition.
  bool get canAcceptEditorInput => canEdit && !_historyExecuting && _projectionPending == 0;

  /// Whether a native undo group is currently available and the editor can write.
  bool get canUndo => canAcceptEditorInput && editorState.editable && _historyState.undoDepth > 0;

  /// Whether a native redo group is currently available and the editor can write.
  bool get canRedo => canAcceptEditorInput && editorState.editable && _historyState.redoDepth > 0;

  /// Replay one local group through Rust, then project and restore its relative
  /// selection. Concurrent invocations share the in-flight operation. Native
  /// failures are reported without clearing history or changing connection state.
  Future<void> undo() => _requestNativeHistory(false);

  /// Replay one undone group through Rust, with the same ownership, permission,
  /// persistence and selection guarantees as [undo]. No server ACK is implied.
  Future<void> redo() => _requestNativeHistory(true);

  /// Capture [transaction]'s pre-edit stable endpoints while the old tree exists.
  void _captureHistoryTransaction(Transaction transaction) {
    _historyTransaction = transaction;
    _beforeHistorySelection = captureNativeEditorSelection(
      editorState,
      transaction.beforeSelection ?? editorState.selection,
      AppFlowyBlockEditorAdapter.collabBlockIdAttribute,
    );
  }

  /// Keep a personal relative bookmark only while native data and UI are aligned.
  void _captureLiveSelection() {
    if (!_nativeHistoryReady ||
        _disposed ||
        _projectionPending != 0 ||
        _historyExecuting ||
        !CollabRuntime.owns(this)) {
      return;
    }
    try {
      _liveSelectionBookmark = native_history.bookmarkDocumentSelection(
        selection: captureNativeEditorSelection(
          editorState,
          editorState.selection,
          AppFlowyBlockEditorAdapter.collabBlockIdAttribute,
        ),
      );
    } catch (error, stack) {
      _services.report('选区书签捕获失败', error, stack, 'DocCollab');
      _liveSelectionBookmark = null;
    }
  }

  /// Pause local transactions to match the current native owner's availability.
  /// Permission/preview stays on editable; pausing never emits a fake revocation
  /// or detaches the keyboard. Only this controller owns this native editor pause.
  void _syncLocalTransactionPause() {
    editorState.localTransactionsPaused = !canAcceptEditorInput;
  }

  /// Serialize one [redo] request; true replays redo and false requests undo.
  /// No stale owner can call the successor engine.
  Future<void> _requestNativeHistory(bool redo) {
    if (_historyTask != null) return _historyTask!;
    if (!(redo ? canRedo : canUndo)) return Future<void>.value();
    return _historyTask = _performNativeHistory(redo).whenComplete(() {
      _historyTask = null;
    });
  }

  /// Persist one transition before touching Flutter content or paths.
  /// [redo] chooses redo when true, undo otherwise. Input is paused separately
  /// from permission so selection replay keeps an existing input connection.
  Future<void> _performNativeHistory(bool redo) async {
    _historyExecuting = true;
    _syncLocalTransactionPause();
    _notify();
    try {
      Future<void> pending;
      do {
        pending = _projection;
        await pending;
      } while (!_disposed && !identical(pending, _projection));
      if (_disposed ||
          _busy ||
          !CollabRuntime.owns(this) ||
          !_editable ||
          !editorState.editable ||
          _readOnlyReason != null) {
        return;
      }
      native_history.configureDocumentHistory(editable: _editable);
      final selection = captureNativeEditorSelection(
        editorState,
        editorState.selection,
        AppFlowyBlockEditorAdapter.collabBlockIdAttribute,
      );
      final result = redo
          ? native_history.redoDocument(selection: selection)
          : native_history.undoDocument(selection: selection);
      _lastBlocks = List.unmodifiable(result.blocks);
      _historyState = result.history;
      _liveSelectionBookmark = result.selectionBookmark;
      _error = null;
      _syncBlockLocks();
      try {
        _session?.sendLocalUpdate(result.v1Update);
      } catch (error, stack) {
        _services.report('历史更新已落盘但即时发送失败', error, stack, 'DocCollab');
        _error = '撤销或重做已保存在本地，重新连接后继续同步';
      }
      await _queueProjection();
    } catch (error, stack) {
      _services.report('原生撤销/重做被拒绝', error, stack, 'DocCollab');
      if (!_disposed) _error = '撤销或重做失败，正文和历史已保留，可重试';
    } finally {
      _historyExecuting = false;
      if (!_disposed) {
        _syncLocalTransactionPause();
        _notify();
      }
    }
  }

  /// 当前文档打开时恢复的 SQLite update 数量。
  int get persistedUpdateCount => _persistedUpdateCount;

  /// 当前 Rust 文档投影块数。
  int get blockCount => _lastBlocks.length;

  /// 最近 Awareness 中其他活动编辑器数量，不等同唯一用户数。
  int get remoteEditorCount => _remoteEditorCount;

  /// 本地及协同展示状态。
  ConnectionStatus get status => _status;

  /// 本地文档已可编辑；离线仍为 true。
  bool get initialized => _initialized;

  /// 切换连接或重置缓存执行中，禁止重复命令。
  bool get busy => _busy || _initializing;

  /// 借用编辑器状态；释放由本控制器负责。
  EditorState get editorState => _editorAdapter.editorState;

  /// 初始化原生绑定、恢复本地正文并注册会话，完成不表示服务端ACK。
  /// 并发调用共享任务；失败完成清理后允许重试，其他控制器占用时在访问文档前失败。
  /// 关闭后返回失败Future，不重新创建编辑或原生资源。
  Future<void> initialize() {
    if (_disposed) return Future<void>.error(StateError('COLLAB_CONTROLLER_CLOSED'));
    return _initializationTask ??= _initializeRecoverably();
  }

  /// 等待初始化及失败清理完成后清除失败任务，使下一次调用重新取得文档所有权。
  Future<void> _initializeRecoverably() async {
    try {
      await _initialize();
    } catch (_) {
      _initializationTask = null;
      rethrow;
    }
  }

  /// Acquire the single Doc before any asynchronous work; close waits for this
  /// task so an initialization finishing late cannot reopen a disposed controller.
  Future<void> _initialize() async {
    if (_disposed) throw StateError('COLLAB_CONTROLLER_CLOSED');
    _initializing = true;
    try {
      config.validate();
      if (config.isFormal && _gateway == null) {
        throw StateError('COLLAB_GATEWAY_REQUIRED');
      }
      CollabRuntime.acquire(this, _services);
      await CollabRuntime.initialize();
      if (_disposed) return;
      await _openLocal(config.cacheDocumentId, formalDocumentId: config.isFormal ? config.documentId : null);
      if (_disposed) return;
      _initialized = true;
      _status = ConnectionStatus.offline;
      _lastProtocolEvent = 'local-updates-loaded';
      if (config.isFormal) {
        await _startSession();
        // 头部是独立业务读取；网络失败或超时不能阻塞已恢复的离线正文。
        // 读取自身处理异常，关闭流程仍等待进行中的请求。
        if (!_disposed) unawaited(header?.refresh() ?? Future<void>.value());
      }
    } catch (error, stackTrace) {
      _initialized = false;
      _setError(error, stackTrace);
      if (CollabRuntime.owns(this)) {
        try {
          await _releaseSession();
        } catch (cleanupError, cleanupStack) {
          _services.report('初始化失败后的监听清理失败', cleanupError, cleanupStack, 'DocCollab');
        } finally {
          if (CollabRuntime.nativeReady) rust.closeDocument();
          CollabRuntime.release(this);
        }
      }
      rethrow;
    } finally {
      _initializing = false;
      if (!_disposed) {
        editorState.editable = canEdit;
        _syncLocalTransactionPause();
      }
      _notify();
    }
  }

  /// Apply the host's [editable] permission immediately. Revocation stops local
  /// writes and submission of upload results, and pauses sync before any cached diff is sent.
  /// Restoring permission starts a new vector handshake with the borrowed socket.
  /// Future报告本轮注册失败；内部队列在记录失败后恢复，后续切换和关闭仍可继续。
  Future<void> setEditable(bool editable) {
    if (_disposed || editable == _editable) return _accessTransition;
    _editable = editable;
    if (_nativeHistoryReady && CollabRuntime.owns(this)) {
      _historyState = native_history.configureDocumentHistory(editable: editable);
    }
    header?.permissionsChanged();
    editorState.editable = canEdit;
    _syncLocalTransactionPause();
    _notify();
    final transition = _accessTransition.then((_) async {
      if (_disposed) return;
      if (_session != null) await _releaseSession();
      if (!_disposed && initialized && config.isFormal) await _startSession();
    });
    _accessTransition = transition.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _setError(error, stackTrace);
      },
    );
    return transition;
  }

  /// Request a fresh join after host connection recovery; terminal errors remain.
  void resync() => _session?.resync();

  /// 重试握手或缓存重置后的注册；初始化失败时先重新取得并打开所属文档。
  /// 其他控制器仍占用引擎时Future失败，不访问或发送其正文，不重连宿主物理连接。
  Future<void> retry() async {
    if (_disposed || busy || !config.isFormal) return;
    await _accessTransition;
    if (_disposed || busy) return;
    if (!initialized) {
      await initialize();
      return;
    }
    if (_session == null) {
      await _startSession();
    } else {
      _session!.retry();
    }
  }

  /// 打开 [cacheId] 的持久化引擎；草稿只保留正文。
  /// [formalDocumentId] 非 null 时指定正式根 ID，使用 BlockCraft 引擎且禁止插入 Demo 头部。
  /// null 仅用于独立本地草稿；正式根 ID 与缓存哈希键必须分开传递。
  /// Future 在 AppFlowy 投影完成后结束，调用者负责确保旧会话已释放。
  /// 同时清除旧文档的身份映射与本地撤销历史，并刷新块权限；禁止历史操作跨缓存或账号恢复。
  Future<void> _openLocal(String cacheId, {String? formalDocumentId}) async {
    final result = formalDocumentId == null
        ? rust.openDocument(documentId: cacheId, databasePath: config.databasePath)
        : rust.openCsesDocument(
            documentId: formalDocumentId,
            cacheDocumentId: cacheId,
            databasePath: config.databasePath,
          );
    _lastBlocks = List.unmodifiable(result.blocks);
    _editorAdapter.resetDocumentHistory();
    _liveSelectionBookmark = null;
    _historyTransaction = null;
    _beforeHistorySelection = null;
    _historyState = native_history.configureDocumentHistory(editable: _editable);
    _nativeHistoryReady = true;
    _syncLocalTransactionPause();
    editorState.undoManager.externalHistory = EditorHistoryDelegate(
      undo: () => unawaited(undo()),
      redo: () => unawaited(redo()),
      canUndo: () => canUndo,
      canRedo: () => canRedo,
    );
    _readOnlyReason = rust.documentReadOnlyReason();
    _syncBlockLocks();
    _sharedTypeName = result.sharedTypeName;
    _persistedUpdateCount = result.persistedUpdateCount;
    await _queueProjection();
  }

  /// 为已持有的文档注册会话；每个回调同时核对原生所有权和当前会话身份。
  /// 只读仅发空握手增量；失效回调不访问后继文档，注册异常向装配方传播。
  Future<void> _startSession() async {
    if (_disposed || _gateway == null) return;
    if (!initialized || !CollabRuntime.owns(this)) throw StateError('COLLAB_DOCUMENT_NOT_OWNED');
    _status = ConnectionStatus.connecting;
    _error = null;
    late final CsesDocCollaborationSession session;
    session = CsesDocCollaborationSession(
      gateway: _gateway,
      documentId: config.documentId,
      instanceId: _services.newId(),
      onAwarenessSessionStarted: () {
        _requireCurrentSession(session);
        rust.beginAwarenessSession();
      },
      stateVectorFactory: () {
        _requireCurrentSession(session);
        return rust.encodeStateVector();
      },
      onSync: (update, vector) {
        _requireCurrentSession(session);
        _applyRemoteUpdate(update);
        // 完整向量握手后再修复结构派生编号，避免把不完整远端增量误当成完整列表。
        // 只读/预览不写入；同一编号已正确时不产生事务或持久化记录。
        if (canEdit && editorState.editable && _lastBlocks.any((block) => block.ordered?.needsRepair == true)) {
          final repaired = rust.applyBlockSnapshot(blocks: _lastBlocks);
          _lastBlocks = List.unmodifiable(repaired.blocks);
          unawaited(_queueProjection());
        }
        return _editable ? rust.encodeDocumentDiff(stateVector: vector) : Uint8List.fromList([0, 0]);
      },
      onUpdate: (bytes) {
        _requireCurrentSession(session);
        _applyRemoteUpdate(bytes);
      },
      awarenessFactory: (present) {
        if (present) _requireCurrentSession(session);
        // 退出时会话已摘除，但只有原所有者可以写自己的离开状态。
        if (!CollabRuntime.owns(this)) throw StateError('COLLAB_DOCUMENT_NOT_OWNED');
        return rust.encodeLocalAwareness(
          userId: config.userId,
          userName: config.userName.isEmpty ? config.userId : config.userName,
          present: present,
        );
      },
      onAwareness: (bytes) {
        _requireCurrentSession(session);
        _remoteEditorCount = rust.applyAwarenessUpdate(bytes: bytes);
        _notify();
      },
      onDisconnected: () {
        if (!_isCurrentSession(session)) return;
        rust.clearRemoteAwareness();
        _remoteEditorCount = 0;
      },
      onStateChanged: (state, event, error) {
        if (_isCurrentSession(session)) _handleSessionState(state, event, error);
      },
    );
    _session = session;
    try {
      await session.start();
    } catch (error, stackTrace) {
      try {
        if (identical(_session, session)) {
          await _releaseSession();
        } else {
          await session.dispose();
        }
      } catch (cleanupError, cleanupStack) {
        _services.report('会话注册失败后的监听清理失败', cleanupError, cleanupStack, 'DocCollab');
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    if (!_isCurrentSession(session)) return;
    _notify();
  }

  /// 判断借用的[session]是否仍属于本控制器及当前原生文档，关闭或替换后失效。
  bool _isCurrentSession(CsesDocCollaborationSession session) =>
      !_disposed && CollabRuntime.owns(this) && identical(_session, session);

  /// 在访问原生文档前核对[session]；过期会话抛出StateError交由协议异常边界停止发送。
  void _requireCurrentSession(CsesDocCollaborationSession session) {
    if (!_isCurrentSession(session)) throw StateError('COLLAB_SESSION_STALE');
  }

  /// 持久化编辑器 [nextBlocks] 的规范化快照；仅本地事务产生上行 update。
  /// 离线/握手期间不发消息，下一轮状态向量会补齐。失败由唯一日志及展示边界处理。
  /// 显式编号设置与后续派生序号共用原生事务；锁定区域、非法设置或表格结构/布局在写前拒绝，失败恢复UI。
  void _applyEditorBlocks(List<CollabEditorBlock> nextBlocks) {
    if (!_initialized || _disposed || _busy) return;
    if (!canAcceptEditorInput) {
      unawaited(_queueProjection());
      return;
    }
    try {
      final blocks = _toRustBlocks(nextBlocks);
      if (_rustBlocksEqual(blocks, _lastBlocks)) return;
      final result = native_history.applyHistorySnapshot(
        blocks: blocks,
        beforeSelection: _beforeHistorySelection,
        afterSelection: captureNativeEditorSelection(
          editorState,
          _historyTransaction?.afterSelection ?? editorState.selection,
          AppFlowyBlockEditorAdapter.collabBlockIdAttribute,
        ),
      );
      _historyState = result.history;
      _liveSelectionBookmark = result.selectionBookmark;
      _historyTransaction = null;
      _beforeHistorySelection = null;
      _error = null;
      _lastBlocks = List.unmodifiable(result.blocks);
      _lastProtocolEvent = 'local-block-update';
      _syncBlockLocks();
      _session?.sendLocalUpdate(result.v1Update);
      if (!_editorBlocksEqual(_toEditorBlocks(result.blocks), nextBlocks)) {
        unawaited(_queueProjection());
      }
      _notify();
    } catch (error, stackTrace) {
      final message = error.toString();
      if (message.contains('UNSUPPORTED_BLOCK_TYPE') ||
          message.contains('READ_ONLY_DOCUMENT') ||
          message.contains('READ_ONLY_BLOCK') ||
          message.contains('INVALID_IMAGE_PROPERTIES') ||
          message.contains('INVALID_TABLE') ||
          message.contains('INVALID_ORDERED_PROPERTIES') ||
          message.contains('INVALID_BLOCK_CONVERSION') ||
          message.contains('BLOCK_ID_CONFLICT')) {
        _services.report('正文块操作被原生校验拒绝', error, stackTrace, 'DocCollab');
        _error = '该操作不适用于当前文档，已恢复原内容';
        _notify();
      } else {
        _setError(error, stackTrace);
      }
      // Rust 前置校验失败时没有改动权威文档；还原 UI，避免已拒绝的块操作留在编辑器。
      unawaited(_queueProjection());
    }
  }

  /// 应用未包帧的远端 V1 [bytes]；Rust 验证正式结构，再更新 Doc/SQLite，不回发。
  /// 未知块和未适配容器仅投影为只读占位，其他块仍可编辑；未适配行内对象保护所在段落，块锁按子树生效，修订仍保护整篇文档。
  /// 协同处理异常向上交给会话统一边界；AppFlowy 投影使用串行任务避免交错覆盖。
  void _applyRemoteUpdate(Uint8List bytes) {
    if (_disposed) return;
    final result = rust.applyDocumentUpdate(bytes: bytes);
    _historyState = native_history.documentHistoryState();
    _readOnlyReason = rust.documentReadOnlyReason();
    _syncBlockLocks();
    if (result.changed && !_rustBlocksEqual(result.blocks, _lastBlocks)) {
      _lastBlocks = List.unmodifiable(result.blocks);
      unawaited(_queueProjection());
    }
    _notify();
  }

  /// 串行投影最新 Rust 快照；执行时读取最新状态，销毁后不访问编辑器。
  /// 仅暂停本地事务，不翻转权限/预览状态；相对选区恢复期间保持已有输入连接。
  /// 返回的 Future 完成表示本任务已处理，投影异常由本边界记录且可继续后续投影。
  Future<void> _queueProjection() {
    _projectionPending++;
    _syncLocalTransactionPause();
    _projection = _projection.then((_) async {
      try {
        if (_disposed) return;
        List<rust.CollabBlock> projected;
        do {
          projected = _lastBlocks;
          await _editorAdapter.replaceFromRemote(_toEditorBlocks(projected));
          if (_disposed) return;
        } while (!identical(projected, _lastBlocks));
        final token = _liveSelectionBookmark;
        native_history.HistorySelection? selection;
        if (token != null && CollabRuntime.owns(this)) {
          selection = native_history.resolveDocumentSelection(token: token);
        }
        if (!editorState.editable) selection = null;
        if (selection == null) _liveSelectionBookmark = null;
        restoreNativeEditorSelection(editorState, selection, AppFlowyBlockEditorAdapter.collabBlockIdAttribute);
      } catch (error, stackTrace) {
        _setError(error, stackTrace);
      } finally {
        _projectionPending--;
        if (!_disposed) {
          _syncLocalTransactionPause();
          _notify();
        }
      }
    });
    return _projection;
  }

  /// 映射会话 [state]、[event]、[error]；online 只表示客户端双向差量已发送。
  void _handleSessionState(CsesCollabState state, String event, String? error) {
    if (_disposed) return;
    _status = switch (state) {
      CsesCollabState.offline => ConnectionStatus.offline,
      CsesCollabState.syncing => ConnectionStatus.connecting,
      CsesCollabState.ready => ConnectionStatus.online,
      CsesCollabState.error => ConnectionStatus.error,
    };
    _lastProtocolEvent = event;
    _error = error;
    _notify();
  }

  /// 断开会话后清除当前缓存，保留其他账号和文档的更新；Future 在投影完成后结束。
  /// 重置后保持离线，用户重新连接时从服务器恢复，不能用于删除服务器正文。
  Future<void> resetLocalCache() async {
    if (_disposed || busy || !_initialized) return;
    _busy = true;
    editorState.editable = false;
    _syncLocalTransactionPause();
    _notify();
    try {
      await _historyTask;
      await _releaseSession();
      await _projection;
      if (_disposed) return;
      rust.resetLocalDocument();
      await _openLocal(config.cacheDocumentId, formalDocumentId: config.isFormal ? config.documentId : null);
      if (_disposed) return;
      _lastProtocolEvent = 'local-cache-reset';
      _status = ConnectionStatus.offline;
      _error = null;
    } catch (error, stackTrace) {
      _setError(error, stackTrace);
    } finally {
      _busy = false;
      if (!_disposed) {
        editorState.editable = canEdit;
        _syncLocalTransactionPause();
      }
      _notify();
    }
  }

  /// 注销所属会话与计时器，清除自身文档的远端成员；借用物理连接保持打开。
  /// 先摘除会话令迟到回调失效，注销失败也清理本地成员展示，不触碰其他所有者文档。
  Future<void> _releaseSession() async {
    final session = _session;
    _session = null;
    try {
      await session?.dispose();
    } finally {
      if (session != null && CollabRuntime.owns(this) && CollabRuntime.nativeReady) rust.clearRemoteAwareness();
      _remoteEditorCount = 0;
    }
  }

  /// 记录原始 [error]/[stackTrace] 并显示固定失败文案，避免输出登录配置。
  void _setError(Object error, StackTrace stackTrace) {
    _services.report('编辑器操作失败', error, stackTrace, 'DocCollab');
    if (_disposed) return;
    _status = ConnectionStatus.error;
    _error = '操作失败，本地内容已保留，请检查运行日志';
    _notify();
  }

  /// 发布当前能力与展示状态；真实能力切换同步无页面宿主的编辑权限。
  /// 能力未变时保留页面的预览/导入状态，投影暂停不触发权限通知。
  void _notify() {
    if (_disposed) return;
    final writable = canEdit;
    if (writable != _publishedCanEdit) {
      _publishedCanEdit = writable;
      editorState.editable = writable;
    }
    _syncLocalTransactionPause();
    notifyListeners();
  }

  /// 将 Rust [blocks] 映射为编辑器快照，保留块身份、链接地址与格式；公式/用户/业务实体按单字符及身份字段传递，业务实体携带原始属性以恢复历史。
  /// 同时投影段落默认字符格式、下一段设置与字体分段；不持有原生资源，不在边界写入共享内容。
  static List<CollabEditorBlock> _toEditorBlocks(List<rust.CollabBlock> blocks) {
    return blocks
        .map(
          (block) => CollabEditorBlock(
            id: block.id,
            blockType: block.blockType,
            text: block.text,
            segments: block.segments
                .map(
                  (segment) => CollabEditorTextSegment(
                    text: segment.text,
                    href: segment.href,
                    typography: segment.typography,
                    inlineLatex: segment.inlineLatex,
                    inlineMention: segment.inlineMention,
                    mentionId: segment.mentionId,
                    mentionType: segment.mentionType,
                    mentionAttributes: segment.mentionAttributes,
                    bold: segment.bold,
                    italic: segment.italic,
                    underline: segment.underline,
                    strikethrough: segment.strikethrough,
                    code: segment.code,
                    textColor: segment.textColor,
                    // Rust stores this as a Yrs text attribute; the editor
                    // adapter maps it back to AppFlowy's `bg_color` key.
                    backgroundColor: segment.backgroundColor,
                    superscript: segment.superscript,
                    subscript: segment.subscript,
                  ),
                )
                .toList(growable: false),
            checked: block.checked,
            blockBackgroundColor: block.blockBackgroundColor,
            blockBorderColor: block.blockBorderColor,
            parentId: block.parentId,
            calloutPrefix: block.calloutPrefix,
            blockTextColor: block.blockTextColor,
            alignment: block.alignment,
            indent: block.indent,
            image: _toEditorImage(block.image),
            ordered: _toEditorOrdered(block.ordered),
            code: _toEditorCode(block.code),
            resource: block.resource == null ? null : CollabResource(properties: block.resource!.properties),
            paragraphStyle: block.paragraphStyle == null
                ? null
                : CollabResource(
                    properties: block.paragraphStyle!.properties,
                    propertyEdits: block.paragraphStyle!.propertyEdits,
                  ),
            replacesId: block.replacesId,
          ),
        )
        .toList(growable: false);
  }

  /// 将编辑器 [blocks] 映射为 Rust 输入，传递链接地址、用户/实体显示名、ID与原始属性快照，由Rust验证对象与模式。
  /// 段落设置仅传递显式字段补丁，字体原值随文字分段往返；不在边界外进行 JSON 或 WS 编码。
  static List<rust.CollabBlock> _toRustBlocks(List<CollabEditorBlock> blocks) {
    return blocks
        .map(
          (block) => rust.CollabBlock(
            id: block.id,
            blockType: block.blockType,
            text: block.text,
            segments: block.segments
                .map(
                  (segment) => rust.CollabTextSegment(
                    text: segment.text,
                    href: segment.href,
                    typography: segment.typography,
                    inlineLatex: segment.inlineLatex,
                    inlineMention: segment.inlineMention,
                    mentionId: segment.mentionId,
                    mentionType: segment.mentionType,
                    mentionAttributes: segment.mentionAttributes,
                    bold: segment.bold,
                    italic: segment.italic,
                    underline: segment.underline,
                    strikethrough: segment.strikethrough,
                    code: segment.code,
                    textColor: segment.textColor,
                    // Preserve the ARGB highlight across the Dart-to-Rust
                    // snapshot boundary instead of treating it as local UI.
                    backgroundColor: segment.backgroundColor,
                    superscript: segment.superscript,
                    subscript: segment.subscript,
                  ),
                )
                .toList(growable: false),
            checked: block.checked,
            blockBackgroundColor: block.blockBackgroundColor,
            blockBorderColor: block.blockBorderColor,
            parentId: block.parentId,
            calloutPrefix: block.calloutPrefix,
            blockTextColor: block.blockTextColor,
            alignment: block.alignment,
            indent: block.indent,
            image: _toRustImage(block.image),
            paragraphStyle: block.paragraphStyle == null
                ? null
                : rust.CollabResource(
                    properties: block.paragraphStyle!.properties,
                    propertyEdits: block.paragraphStyle!.propertyEdits,
                  ),
            resource: block.resource == null
                ? null
                : rust.CollabResource(
                    properties: block.resource!.properties,
                    propertyEdits: block.resource!.propertyEdits,
                  ),
            ordered: _toRustOrdered(block.ordered),
            code: block.code == null
                ? null
                : rust.CollabCode(
                    language: block.code!.language,
                    name: block.code!.name,
                    collapsed: block.code!.collapsed,
                    properties: block.code!.properties,
                    propertyEdits: block.code!.propertyEdits,
                  ),
            replacesId: block.replacesId,
          ),
        )
        .toList(growable: false);
  }

  static CollabCode? _toEditorCode(rust.CollabCode? code) => code == null
      ? null
      : CollabCode(
          language: code.language,
          name: code.name,
          collapsed: code.collapsed,
          rawProperties: code.properties,
          propertyEdits: code.propertyEdits,
        );

  /// 将原生图片 [image] 转为展示投影；null 保留普通块/离线草稿语义，题注不展平。
  static CollabImage? _toEditorImage(rust.CollabImage? image) => image == null
      ? null
      : CollabImage(
          widthRatio: image.widthRatio,
          aspectRatio: image.aspectRatio,
          width: image.width,
          height: image.height,
          rotation: image.rotation,
          captions: List.unmodifiable(image.captions.map((c) => CollabImageCaption(id: c.id, text: c.text))),
        );

  /// 将展示图片 [image] 转为桥接参数；尺寸原值和题注身份完整传递，null 不创建题注。
  static rust.CollabImage? _toRustImage(CollabImage? image) => image == null
      ? null
      : rust.CollabImage(
          widthRatio: image.widthRatio,
          aspectRatio: image.aspectRatio,
          width: image.width,
          height: image.height,
          rotation: image.rotation,
          captions: image.captions.map((c) => rust.CollabImageCaption(id: c.id, text: c.text)).toList(growable: false),
        );

  /// 将 Rust [value] 的结构编号及原始设置转为不可变展示投影；null 表示普通块或独立草稿。
  /// 原始设置供菜单及撤销保存，远端投影不携带编号写入意图，也不持有编辑器资源。
  static CollabOrdered? _toEditorOrdered(rust.CollabOrdered? value) => value == null
      ? null
      : CollabOrdered(
          order: value.order,
          start: value.start,
          heading: value.heading,
          markerStyle: value.markerStyle,
          needsRepair: value.needsRepair,
          numbering: value.numbering,
        );

  /// 将展示 [value] 和一次性编号设置意图传回桥接；null 表示普通块。
  /// Rust 只消费 numberingEdit，普通投影不会覆盖 start/continuePrevious，ms 始终保留。
  static rust.CollabOrdered? _toRustOrdered(CollabOrdered? value) => value == null
      ? null
      : rust.CollabOrdered(
          order: value.order,
          start: value.start,
          heading: value.heading,
          markerStyle: value.markerStyle,
          needsRepair: value.needsRepair,
          numbering: value.numbering,
          numberingEdit: value.numberingEdit,
        );

  /// 比较 [left] 与 [right] 的全部块投影和字段补丁；相同才可跳过写入或投影。
  /// 段落样式及显式补丁不能只依赖正文变化触发，否则单独修改设置会被丢弃。
  static bool _rustBlocksEqual(List<rust.CollabBlock> left, List<rust.CollabBlock> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      final leftBlock = left[index];
      final rightBlock = right[index];
      if (leftBlock.id != rightBlock.id ||
          leftBlock.blockType != rightBlock.blockType ||
          leftBlock.text != rightBlock.text ||
          leftBlock.checked != rightBlock.checked ||
          leftBlock.blockBackgroundColor != rightBlock.blockBackgroundColor ||
          leftBlock.blockBorderColor != rightBlock.blockBorderColor ||
          leftBlock.parentId != rightBlock.parentId ||
          leftBlock.calloutPrefix != rightBlock.calloutPrefix ||
          leftBlock.blockTextColor != rightBlock.blockTextColor ||
          leftBlock.alignment != rightBlock.alignment ||
          leftBlock.indent != rightBlock.indent ||
          leftBlock.replacesId != rightBlock.replacesId ||
          _toEditorOrdered(leftBlock.ordered) != _toEditorOrdered(rightBlock.ordered) ||
          _toEditorCode(leftBlock.code) != _toEditorCode(rightBlock.code) ||
          leftBlock.paragraphStyle != rightBlock.paragraphStyle ||
          leftBlock.resource != rightBlock.resource ||
          _toEditorImage(leftBlock.image) != _toEditorImage(rightBlock.image) ||
          !_rustSegmentsEqual(leftBlock.segments, rightBlock.segments)) {
        return false;
      }
    }
    return true;
  }

  /// 按桥接分段的完整值相等比较 [left] 与 [right]，包含字体、链接和对象身份。
  /// 长度或任一字段不同返回false，不修改分段或持有原生资源。
  static bool _rustSegmentsEqual(List<rust.CollabTextSegment> left, List<rust.CollabTextSegment> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }

  static bool _editorBlocksEqual(List<CollabEditorBlock> left, List<CollabEditorBlock> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }

  /// Wait for header/feedback business requests, document subscriptions, projection and native shutdown.
  /// Borrowed host services and the physical socket are not closed.
  /// 结束前移除段落链接绑定，使仍在退场的菜单不能引用已关闭文档。
  Future<void> close() {
    dispose();
    return _shutdownTask ?? Future<void>.value();
  }

  /// Invalidate synchronously; release document listeners and native resources asynchronously.
  /// 同步移除段落链接绑定；Flutter dispose不能等待Future，资源释放任务自行拥有统一异常边界。
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _syncLocalTransactionPause();
    editorState.editable = false;
    editorState.selectionNotifier.removeListener(_captureLiveSelection);
    editorState.undoManager.externalHistory = null;
    _paragraphLinks?.dispose();
    header?.removeListener(_notify);
    header?.dispose();
    feedback.dispose();
    _shutdownTask = _shutdown();
    unawaited(_shutdownTask!);
    super.dispose();
  }

  /// 依次等待初始化、业务请求、权限切换、会话及投影，再关闭所属原生和编辑资源。
  /// 单项失败记录到本实例端口并继续清理；不释放宿主端口或其他控制器的原生文档。
  Future<void> _shutdown() async {
    try {
      await _finishShutdownStep(() async {
        await _initializationTask?.then<void>((_) {}, onError: (Object _, StackTrace _) {});
      });
      await _finishShutdownStep(() async {
        await header?.close();
      });
      await _finishShutdownStep(feedback.close);
      await _finishShutdownStep(() => _accessTransition);
      await _finishShutdownStep(_releaseSession);
      await _finishShutdownStep(() async {
        await _historyTask;
      });
      await _finishShutdownStep(() => _projection);
    } finally {
      if (CollabRuntime.owns(this) && CollabRuntime.nativeReady) {
        rust.closeDocument();
      }
      _blockLocks.dispose();
      _editorAdapter.dispose();
      await editor.close();
      CollabRuntime.release(this);
    }
  }

  /// 等待[operation]释放一项自有资源，失败记录后允许后续关闭步骤继续。
  Future<void> _finishShutdownStep(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error, stackTrace) {
      _services.report('协同资源释放失败', error, stackTrace, 'DocCollab');
    }
  }
}
