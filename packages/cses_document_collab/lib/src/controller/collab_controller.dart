import 'document_feedback_controller.dart';
import 'dart:async';
import 'document_metadata_controller.dart';

import 'package:cses_document_collab/src/model/collab_resource.dart';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_code.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_image.dart';
import 'package:cses_document_collab/src/model/collab_ordered.dart';
import 'package:cses_document_collab/src/sync/cses_collab_gateway.dart';
import 'package:cses_document_collab/src/model/collab_document_config.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/sync/cses_doc_collaboration_session.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as rust;
import 'package:flutter/foundation.dart';

/// 本地加载、主连接握手及协同会话映射出的展示状态；online 不表示数据库落库。
enum ConnectionStatus { starting, connecting, online, offline, error }

/// Owns one native document, local cache and editor; borrows the host gateway.
///
/// Example: `final collab = CollabController.cses(config: config, gateway: gateway);
/// await collab.initialize();` Present `CollaborativeEditorPage(collab: collab)`,
/// then `await collab.close()` before opening another native document.
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
  }) : this._(
         CollabDocumentConfig.localDraft(
           databasePath: databasePath,
           documentId: documentId,
         ),
         null,
         services,
       );

  /// Store [config], [gateway] and [services]; native ownership begins on initialize.
  CollabController._(this.config, this._gateway, this._services)
    : _editable = config.editable {
    header = config.isFormal && _services.documentMetadata != null
        ? DocumentMetadataController(
            documentId: config.documentId,
            service: _services.documentMetadata!,
            canEdit: () => !_disposed && _editable,
            services: _services,
          )
        : null;
    header?.addListener(_notify);
    feedback = DocumentFeedbackController(
      documentId: config.documentId,
      services: _services,
    );
    _editorAdapter = AppFlowyBlockEditorAdapter(
      onLocalBlocksChanged: _applyEditorBlocks,
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

  /// Rust 根据当前根、行内对象、锁和修订计算的只读原因；null 表示结构可编辑。
  /// 此值不代表服务端业务权限，网络断开后仍保留已加载模型的编辑能力。
  String? get readOnlyReason => !_editable ? '宿主权限为只读' : _readOnlyReason;

  /// 当前可提交本地编辑；未加载、切换中、模型只读或发生协同错误时返回 false。
  bool get canEdit =>
      !_disposed &&
      initialized &&
      !busy &&
      _editable &&
      _readOnlyReason == null &&
      _status != ConnectionStatus.error;

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

  /// Initialize native bindings, restore local data and register online callbacks.
  /// Completion means local projection and registration finished, not server ACK.
  /// Concurrent calls share one task. Another controller fails before touching
  /// the process-global Doc; failures remain visible and propagate to the host.
  Future<void> initialize() => _initializationTask ??= _initialize();

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
      await _openLocal(
        config.cacheDocumentId,
        formalDocumentId: config.isFormal ? config.documentId : null,
      );
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
      _setError(error, stackTrace);
      if (CollabRuntime.owns(this)) {
        try {
          await _releaseSession();
        } catch (cleanupError, cleanupStack) {
          _services.report(
            '初始化失败后的监听清理失败',
            cleanupError,
            cleanupStack,
            'DocCollab',
          );
        } finally {
          if (CollabRuntime.nativeReady) rust.closeDocument();
          CollabRuntime.release(this);
        }
      }
      rethrow;
    } finally {
      _initializing = false;
      if (!_disposed) editorState.editable = canEdit;
      _notify();
    }
  }

  /// Apply the host's [editable] permission immediately. Revocation stops local
  /// writes and submission of upload results, and pauses sync before any cached diff is sent.
  /// Restoring permission starts a new vector handshake with the borrowed socket.
  Future<void> setEditable(bool editable) {
    if (_disposed || editable == _editable) return _accessTransition;
    _editable = editable;
    header?.permissionsChanged();
    editorState.editable = canEdit;
    _notify();
    _accessTransition = _accessTransition.then((_) async {
      if (_disposed) return;
      if (_session != null) await _releaseSession();
      if (!_disposed && initialized && config.isFormal) await _startSession();
    });
    return _accessTransition;
  }

  /// Request a fresh join after host connection recovery; terminal errors remain.
  void resync() => _session?.resync();

  /// Explicitly retry a failed handshake, or re-register after a cache reset.
  /// Does not change authentication or reconnect the physical WebSocket.
  Future<void> retry() async {
    if (_disposed || !initialized || busy || !config.isFormal) return;
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
  /// 同时清除旧文档的身份映射与本地撤销历史，禁止历史操作跨缓存或账号恢复。
  Future<void> _openLocal(String cacheId, {String? formalDocumentId}) async {
    final result = formalDocumentId == null
        ? rust.openDocument(
            documentId: cacheId,
            databasePath: config.databasePath,
          )
        : rust.openCsesDocument(
            documentId: formalDocumentId,
            cacheDocumentId: cacheId,
            databasePath: config.databasePath,
          );
    _lastBlocks = List.unmodifiable(result.blocks);
    _editorAdapter.resetDocumentHistory();
    _readOnlyReason = rust.documentReadOnlyReason();
    _sharedTypeName = result.sharedTypeName;
    _persistedUpdateCount = result.persistedUpdateCount;
    await _queueProjection();
  }

  /// Assemble a document-only session. Read-only hosts receive updates but send
  /// only an empty handshake diff, preserving cached edits until authorized.
  Future<void> _startSession() async {
    if (_disposed || _gateway == null) return;
    _status = ConnectionStatus.connecting;
    _error = null;
    final session = CsesDocCollaborationSession(
      gateway: _gateway,
      documentId: config.documentId,
      instanceId: CollabRuntime.services.newId(),
      stateVectorFactory: rust.encodeStateVector,
      onSync: (update, vector) {
        _applyRemoteUpdate(update);
        // 完整向量握手后再修复结构派生编号，避免把不完整远端增量误当成完整列表。
        // 只读/预览不写入；同一编号已正确时不产生事务或持久化记录。
        if (canEdit &&
            editorState.editable &&
            _lastBlocks.any((block) => block.ordered?.needsRepair == true)) {
          final repaired = rust.applyBlockSnapshot(blocks: _lastBlocks);
          _lastBlocks = List.unmodifiable(repaired.blocks);
          unawaited(_queueProjection());
        }
        return _editable
            ? rust.encodeDocumentDiff(stateVector: vector)
            : Uint8List.fromList([0, 0]);
      },
      onUpdate: _applyRemoteUpdate,
      awarenessFactory: (present) => rust.encodeLocalAwareness(
        userId: config.userId,
        userName: config.userName.isEmpty ? config.userId : config.userName,
        present: present,
      ),
      onAwareness: (bytes) {
        _remoteEditorCount = rust.applyAwarenessUpdate(bytes: bytes);
        _notify();
      },
      onDisconnected: () {
        rust.clearRemoteAwareness();
        _remoteEditorCount = 0;
      },
      onStateChanged: _handleSessionState,
    );
    _session = session;
    await session.start();
    if (_disposed) return;
    _notify();
  }

  /// 持久化编辑器 [nextBlocks] 的规范化快照；仅本地事务产生上行 update。
  /// 离线/握手期间不发消息，下一轮状态向量会补齐。失败由唯一日志及展示边界处理。
  /// 显式编号设置与后续派生序号共用原生事务；非法设置不改权威文档并恢复 UI。
  void _applyEditorBlocks(List<CollabEditorBlock> nextBlocks) {
    if (!_initialized || _disposed || _busy) return;
    if (!canEdit) {
      unawaited(_queueProjection());
      return;
    }
    try {
      final blocks = _toRustBlocks(nextBlocks);
      if (_rustBlocksEqual(blocks, _lastBlocks)) return;
      final result = rust.applyBlockSnapshot(blocks: blocks);
      _error = null;
      _lastBlocks = List.unmodifiable(result.blocks);
      _lastProtocolEvent = 'local-block-update';
      _session?.sendLocalUpdate(result.v1Update);
      if (!_editorBlocksEqual(_toEditorBlocks(result.blocks), nextBlocks)) {
        unawaited(_queueProjection());
      }
      _notify();
    } catch (error, stackTrace) {
      final message = error.toString();
      if (message.contains('UNSUPPORTED_BLOCK_TYPE') ||
          message.contains('READ_ONLY_DOCUMENT') ||
          message.contains('INVALID_IMAGE_PROPERTIES') ||
          message.contains('INVALID_ORDERED_PROPERTIES') ||
          message.contains('INVALID_BLOCK_CONVERSION') ||
          message.contains('BLOCK_ID_CONFLICT')) {
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
  /// 未知块和未适配容器仅投影为只读占位，其他块仍可编辑；行内对象、锁和修订继续保护整篇文档。
  /// 协同处理异常向上交给会话统一边界；AppFlowy 投影使用串行任务避免交错覆盖。
  void _applyRemoteUpdate(Uint8List bytes) {
    if (_disposed) return;
    final result = rust.applyDocumentUpdate(bytes: bytes);
    _readOnlyReason = rust.documentReadOnlyReason();
    if (result.changed && !_rustBlocksEqual(result.blocks, _lastBlocks)) {
      _lastBlocks = List.unmodifiable(result.blocks);
      unawaited(_queueProjection());
    }
    _notify();
  }

  /// 串行投影最新 Rust 快照；执行时读取最新状态，销毁后不访问编辑器。
  /// 返回的 Future 完成表示本任务已处理，投影异常由本边界记录且可继续后续投影。
  Future<void> _queueProjection() {
    _projection = _projection.then((_) async {
      if (_disposed) return;
      try {
        await _editorAdapter.replaceFromRemote(_toEditorBlocks(_lastBlocks));
      } catch (error, stackTrace) {
        _setError(error, stackTrace);
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
    _notify();
    try {
      await _releaseSession();
      await _projection;
      if (_disposed) return;
      rust.resetLocalDocument();
      await _openLocal(
        config.cacheDocumentId,
        formalDocumentId: config.isFormal ? config.documentId : null,
      );
      if (_disposed) return;
      _lastProtocolEvent = 'local-cache-reset';
      _status = ConnectionStatus.offline;
      _error = null;
    } catch (error, stackTrace) {
      _setError(error, stackTrace);
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// Release only document callbacks and timers; the borrowed socket stays open.
  Future<void> _releaseSession() async {
    final session = _session;
    _session = null;
    await session?.dispose();
    _remoteEditorCount = 0;
  }

  /// 记录原始 [error]/[stackTrace] 并显示固定失败文案，避免输出登录配置。
  void _setError(Object error, StackTrace stackTrace) {
    _services.report('编辑器操作失败', error, stackTrace, 'DocCollab');
    if (_disposed) return;
    _status = ConnectionStatus.error;
    _error = '操作失败，本地内容已保留，请检查运行日志';
    _notify();
  }

  /// 向仍存活的页面发布变更，不在销毁后回写 UI。
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 将 Rust [blocks] 映射为编辑器快照，保留块身份与格式；公式/用户/业务实体按单字符及身份字段传递，业务实体携带原始属性以恢复历史。
  /// 不持有原生资源，不在边界写入共享内容。
  static List<CollabEditorBlock> _toEditorBlocks(
    List<rust.CollabBlock> blocks,
  ) {
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
            resource: block.resource == null
                ? null
                : CollabResource(properties: block.resource!.properties),
            replacesId: block.replacesId,
          ),
        )
        .toList(growable: false);
  }

  /// 将编辑器 [blocks] 映射为 Rust 输入，传递用户/实体显示名、ID与原始属性快照，由Rust验证对象与模式。
  /// 不在边界外进行 JSON 或 WS 编码。
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
          captions: List.unmodifiable(
            image.captions.map(
              (c) => CollabImageCaption(id: c.id, text: c.text),
            ),
          ),
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
          captions: image.captions
              .map((c) => rust.CollabImageCaption(id: c.id, text: c.text))
              .toList(growable: false),
        );

  /// 将 Rust [value] 的结构编号及原始设置转为不可变展示投影；null 表示普通块或独立草稿。
  /// 原始设置供菜单及撤销保存，远端投影不携带编号写入意图，也不持有编辑器资源。
  static CollabOrdered? _toEditorOrdered(rust.CollabOrdered? value) =>
      value == null
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
  static rust.CollabOrdered? _toRustOrdered(CollabOrdered? value) =>
      value == null
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

  /// 比较 [left]/[right] 的全部投影字段，图片尺寸和题注变化也必须触发 UI 投影。
  static bool _rustBlocksEqual(
    List<rust.CollabBlock> left,
    List<rust.CollabBlock> right,
  ) {
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
          _toEditorOrdered(leftBlock.ordered) !=
              _toEditorOrdered(rightBlock.ordered) ||
          _toEditorCode(leftBlock.code) != _toEditorCode(rightBlock.code) ||
          leftBlock.resource?.properties != rightBlock.resource?.properties ||
          _toEditorImage(leftBlock.image) != _toEditorImage(rightBlock.image) ||
          !_rustSegmentsEqual(leftBlock.segments, rightBlock.segments)) {
        return false;
      }
    }
    return true;
  }

  static bool _rustSegmentsEqual(
    List<rust.CollabTextSegment> left,
    List<rust.CollabTextSegment> right,
  ) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      final leftSegment = left[index];
      final rightSegment = right[index];
      if (leftSegment.text != rightSegment.text ||
          leftSegment.bold != rightSegment.bold ||
          leftSegment.italic != rightSegment.italic ||
          leftSegment.underline != rightSegment.underline ||
          leftSegment.strikethrough != rightSegment.strikethrough ||
          leftSegment.code != rightSegment.code ||
          leftSegment.textColor != rightSegment.textColor ||
          leftSegment.backgroundColor != rightSegment.backgroundColor ||
          leftSegment.superscript != rightSegment.superscript ||
          leftSegment.subscript != rightSegment.subscript) {
        return false;
      }
    }
    return true;
  }

  static bool _editorBlocksEqual(
    List<CollabEditorBlock> left,
    List<CollabEditorBlock> right,
  ) {
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
  Future<void> close() {
    dispose();
    return _shutdownTask ?? Future<void>.value();
  }

  /// Invalidate synchronously; release document listeners and native resources asynchronously.
  /// Flutter dispose 不能等待 Future，资源释放任务自行拥有统一异常边界。
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    header?.removeListener(_notify);
    header?.dispose();
    feedback.dispose();
    _shutdownTask = _shutdown();
    unawaited(_shutdownTask!);
    super.dispose();
  }

  /// 等待业务头部/文末互动读写、会话释放及已排队投影，再关闭所属全局Rust引擎；宿主端口不释放。
  Future<void> _shutdown() async {
    try {
      await _initializationTask?.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      await header?.close();
      await feedback.close();
      await _accessTransition;
      await _releaseSession();
      await _projection;
    } catch (error, stackTrace) {
      CollabDiagnostics.report(
        'Demo 协同资源释放失败',
        error: error,
        stackTrace: stackTrace,
        tag: 'DocCollab',
      );
    } finally {
      if (CollabRuntime.owns(this) && CollabRuntime.nativeReady) {
        rust.closeDocument();
      }
      _editorAdapter.dispose();
      CollabRuntime.release(this);
    }
  }
}
