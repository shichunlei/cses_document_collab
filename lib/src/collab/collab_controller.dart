import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_common/core/collections/objectid.dart';
import 'package:cses_common/observability/api/log.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:cses_mobile_collab_demo/src/collab/collab_image.dart';
import 'package:cses_mobile_collab_demo/src/collab/collab_ordered.dart';
import 'package:cses_mobile_collab_demo/src/collab/cses_collab_gateway.dart';
import 'package:cses_mobile_collab_demo/src/collab/cses_connection_settings.dart';
import 'package:cses_mobile_collab_demo/src/collab/cses_demo_host.dart';
import 'package:cses_mobile_collab_demo/src/collab/cses_doc_collaboration_session.dart';
import 'package:cses_mobile_collab_demo/src/rust/api/collab.dart' as rust;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// 本地加载、主连接握手及协同会话映射出的展示状态；online 不表示数据库落库。
enum ConnectionStatus { starting, connecting, online, offline, error }

/// 独立 Demo 的装配边界，拥有唯一 Rust Doc、编辑器和应用级 CSES 主连接。
///
/// 不依赖 SaaS 详情页。本地更新先写 SQLite，再按会话 ready 状态发送原始 V1 update；
/// 远端仅应用到 Rust 和编辑器，禁止回发。Demo 同时只允许一个控制器持有全局 Rust 引擎。
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/collab/collab_controller.dart';
/// import 'package:cses_mobile_collab_demo/src/collab/cses_connection_settings.dart';
/// Future<void> useEditor(CsesConnectionSettings settings) async {
///   final controller = CollabController();
///   await controller.initialize();
///   await controller.configureCses(settings);
///   // 页面使用 controller.editorState；退出前保持同一控制器。
///   controller.dispose();
/// }
/// ```
class CollabController extends ChangeNotifier with WidgetsBindingObserver {
  /// 创建离线编辑器；[_documentId] 是未登录时的本地草稿键，默认 demo-room。
  /// 不自动连接 CSES，不读取持久化凭证；登录后的宿主负责触发主连接。
  CollabController({this._documentId = 'demo-room'}) {
    _editorAdapter = AppFlowyBlockEditorAdapter(
      onLocalBlocksChanged: _applyEditorBlocks,
    );
  }

  String _documentId;
  late final AppFlowyBlockEditorAdapter _editorAdapter;
  final CsesDemoHost _host = const CsesDemoHost();
  CsesConnectionSettings? _settings;
  CsesDocCollaborationSession? _session;
  Future<void> _projection = Future<void>.value();
  String? _databasePath;
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
  bool _observingLifecycle = false;

  /// 当前线上 docId，未连接时为本地草稿标识。
  String get documentId => _documentId;

  /// 当前稳定失败文案，不含输入凭证。
  String? get error => _error;

  /// 最近协议阶段，用于实验观察，不是保存回执。
  String get lastProtocolEvent => _lastProtocolEvent;

  /// 当前模型根名称；本地草稿为 Demo 块顺序，CSES 正式文档为 blocks。
  String get sharedTypeName => _sharedTypeName;

  /// Rust 根据当前根、未知块、锁和修订计算的只读原因；null 表示结构可编辑。
  /// 此值不代表服务端业务权限，网络断开后仍保留已加载模型的编辑能力。
  String? get readOnlyReason => _readOnlyReason;

  /// 当前可提交本地编辑；未加载、切换中、模型只读或发生协同错误时返回 false。
  bool get canEdit =>
      !_disposed &&
      initialized &&
      !busy &&
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

  /// 加载本地草稿，Future 在编辑器投影完成后结束；失败记录并展示，不连接网络。
  Future<void> initialize() async {
    if (_disposed || _initialized || _initializing) return;
    _initializing = true;
    try {
      final directory = await getApplicationSupportDirectory();
      if (_disposed) return;
      _databasePath =
          '${directory.path}/cses_mobile_collab_demo/updates.sqlite3';
      await _openLocal(_documentId);
      if (_disposed) return;
      _initialized = true;
      _status = ConnectionStatus.offline;
      _lastProtocolEvent = 'local-updates-loaded';
      WidgetsBinding.instance.addObserver(this);
      _observingLifecycle = true;
    } catch (error, stackTrace) {
      _setError(error, stackTrace);
    } finally {
      _initializing = false;
      _notify();
    }
  }

  /// 打开 [cacheId] 的持久化引擎；[initializeHeaders] 默认 true，补齐本地草稿头部。
  /// [formalDocumentId] 非 null 时指定正式根 ID，使用 BlockCraft 引擎且禁止插入 Demo 头部。
  /// null 仅用于独立本地草稿；正式根 ID 与缓存哈希键必须分开传递。
  /// Future 在 AppFlowy 投影完成后结束，调用者负责确保旧会话已释放。
  /// 同时清除旧文档的身份映射与本地撤销历史，禁止历史操作跨缓存或账号恢复。
  Future<void> _openLocal(
    String cacheId, {
    bool initializeHeaders = true,
    String? formalDocumentId,
  }) async {
    final result = formalDocumentId == null
        ? rust.openDocument(documentId: cacheId, databasePath: _databasePath!)
        : rust.openCsesDocument(
            documentId: formalDocumentId,
            cacheDocumentId: cacheId,
            databasePath: _databasePath!,
          );
    _lastBlocks = List.unmodifiable(result.blocks);
    _editorAdapter.resetDocumentHistory();
    if (initializeHeaders && formalDocumentId == null) _ensureHeaders();
    _readOnlyReason = rust.documentReadOnlyReason();
    _sharedTypeName = result.sharedTypeName;
    _persistedUpdateCount = result.persistedUpdateCount;
    await _queueProjection();
  }

  /// 在权威快照缺少头部时才补齐并持久化；已有服务端标题/封面不会重复插入默认文本。
  /// 串行投影使用最新快照，不发独立 update；握手调用方通过状态向量补传此迁移。
  void _ensureHeaders() {
    final blocks = _toRustBlocks(
      ensureCsesDocumentHeaderBlocks(_toEditorBlocks(_lastBlocks)),
    );
    if (_rustBlocksEqual(blocks, _lastBlocks)) return;
    _lastBlocks = List.unmodifiable(
      rust.applyBlockSnapshot(blocks: blocks).blocks,
    );
    unawaited(_queueProjection());
  }

  /// 使用已有登录 [settings] 切换正式 BlockCraft 文档并注册协同；不创建业务文档或执行登录。
  ///
  /// Future 在注册和主连接初始化调度完成后结束，真正 ready 等待 collabSync。
  /// 校验错误只显示可操作文案；账号/企业/地址/文档共同隔离本机缓存，不混入草稿。
  /// 完整同步且允许编辑时，补齐缺失/过期列表编号并纳入当前状态向量差量；预览/只读不写回。
  Future<void> configureCses(CsesConnectionSettings settings) async {
    if (_disposed || busy || !_initialized) return;
    _busy = true;
    _notify();
    try {
      settings.validate();
      await _releaseSession();
      if (_disposed) return;
      await _projection;
      if (_disposed) return;
      _settings = settings;
      _documentId = settings.documentId;
      _initialized = false;
      await _openLocal(
        settings.cacheDocumentId,
        initializeHeaders: false,
        formalDocumentId: settings.documentId,
      );
      if (_disposed) return;
      _initialized = true;
      await _host.configure(settings);
      if (_disposed) {
        _host.close();
        return;
      }
      _status = ConnectionStatus.connecting;
      _error = null;
      final session = CsesDocCollaborationSession(
        gateway: CommonCsesCollabGateway(),
        documentId: settings.documentId,
        instanceId: ObjectId().toString(),
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
          return rust.encodeDocumentDiff(stateVector: vector);
        },
        onUpdate: _applyRemoteUpdate,
        awarenessFactory: (present) => rust.encodeLocalAwareness(
          userId: settings.userId,
          userName: settings.userId,
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
      await _host.connect();
    } on FormatException catch (error) {
      _status = ConnectionStatus.error;
      _error = error.message;
    } catch (error, stackTrace) {
      _setError(error, stackTrace);
    } finally {
      _busy = false;
      _notify();
    }
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
      final blocks = _toRustBlocks(
        _settings == null
            ? ensureCsesDocumentHeaderBlocks(nextBlocks)
            : nextBlocks,
      );
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
  /// 未知块、嵌套容器、行内对象、锁和修订保留原始类型，并重新计算只读能力。
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
        _settings?.cacheDocumentId ?? _documentId,
        initializeHeaders: _settings == null,
        formalDocumentId: _settings?.documentId,
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

  /// 先释放文档监听，再关闭本 Demo 专有主连接和凭证；Future 在本地注销后结束。
  Future<void> _releaseSession() async {
    final session = _session;
    _session = null;
    await session?.dispose();
    if (_settings != null) _host.close();
    _remoteEditorCount = 0;
  }

  /// 回到前台时复用 Common 主连接恢复机制；[state] 为 resumed 时重新协同。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _session != null &&
        !_busy &&
        !_disposed) {
      unawaited(_resume());
    }
  }

  /// 前台恢复的异常边界，不创建独立 Socket；Future 在初始化调度后结束。
  Future<void> _resume() async {
    try {
      final ready = await _host.recover();
      if (!_disposed && ready) _session?.resync();
    } catch (error, stackTrace) {
      _setError(error, stackTrace);
    }
  }

  /// 记录原始 [error]/[stackTrace] 并显示固定失败文案，避免输出登录配置。
  void _setError(Object error, StackTrace stackTrace) {
    Log.e(
      'Demo 编辑器操作失败',
      error: error,
      stackTrace: stackTrace,
      tag: 'DocCollabDemo',
    );
    if (_disposed) return;
    _status = ConnectionStatus.error;
    _error = '操作失败，本地内容已保留，请检查运行日志';
    _notify();
  }

  /// 向仍存活的页面发布变更，不在销毁后回写 UI。
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 将 Rust [blocks] 映射为编辑器快照，保留块身份和全部受支持的富文本属性。
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
            alignment: block.alignment,
            indent: block.indent,
            image: _toEditorImage(block.image),
            ordered: _toEditorOrdered(block.ordered),
            replacesId: block.replacesId,
          ),
        )
        .toList(growable: false);
  }

  /// 将编辑器 [blocks] 映射为 Rust 输入，不在边界外进行 JSON 或 WS 编码。
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
            alignment: block.alignment,
            indent: block.indent,
            image: _toRustImage(block.image),
            ordered: _toRustOrdered(block.ordered),
            replacesId: block.replacesId,
          ),
        )
        .toList(growable: false);
  }

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
          leftBlock.alignment != rightBlock.alignment ||
          leftBlock.indent != rightBlock.indent ||
          leftBlock.replacesId != rightBlock.replacesId ||
          _toEditorOrdered(leftBlock.ordered) !=
              _toEditorOrdered(rightBlock.ordered) ||
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

  /// 释放控制器并等待 Socket、投影与 Rust 文档关闭；退出账号前必须等待。
  Future<void> close() {
    dispose();
    return _shutdownTask ?? Future<void>.value();
  }

  /// 同步标记失效，停止 Widget 监听；后台顺序注销 WS、关闭引擎并记录释放异常。
  /// Flutter dispose 不能等待 Future，资源释放任务自行拥有统一异常边界。
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_observingLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
      _observingLifecycle = false;
    }
    _editorAdapter.dispose();
    _shutdownTask = _shutdown();
    unawaited(_shutdownTask!);
    super.dispose();
  }

  /// 等待会话释放及已排队投影结束，再关闭本控制器拥有的全局 Rust 引擎。
  Future<void> _shutdown() async {
    try {
      await _releaseSession();
      await _projection;
      if (_databasePath != null) rust.closeDocument();
    } catch (error, stackTrace) {
      Log.e(
        'Demo 协同资源释放失败',
        error: error,
        stackTrace: stackTrace,
        tag: 'DocCollabDemo',
      );
    }
  }
}

/// Adds the fixed Feishu-style cover/title region to old or empty documents.
///
/// Header IDs are deterministic across clients, preventing two offline phones
/// from inventing competing title blocks while migrating the same room. Any
/// existing header content is preserved and moved ahead of ordinary body
/// blocks; a document with no body also receives one editable paragraph.
List<CollabEditorBlock> ensureCsesDocumentHeaderBlocks(
  List<CollabEditorBlock> blocks,
) {
  CollabEditorBlock? cover;
  CollabEditorBlock? title;
  final body = <CollabEditorBlock>[];
  for (final block in blocks) {
    if (block.blockType == csesDocumentCoverBlockType && cover == null) {
      cover = block;
    } else if (block.blockType == csesDocumentTitleBlockType && title == null) {
      title = block;
    } else if (block.blockType != csesDocumentCoverBlockType &&
        block.blockType != csesDocumentTitleBlockType) {
      body.add(block);
    }
  }

  cover ??= const CollabEditorBlock(
    id: csesDocumentCoverBlockId,
    blockType: csesDocumentCoverBlockType,
    // Only a genuinely missing cover receives the product default. An existing
    // cover block with empty text represents an intentional user removal and
    // is preserved by the normalization loop above.
    text: csesDefaultDocumentCoverUrl,
  );
  title ??= const CollabEditorBlock(
    id: csesDocumentTitleBlockId,
    blockType: csesDocumentTitleBlockType,
    text: '未命名文档',
  );
  if (body.isEmpty) {
    body.add(
      const CollabEditorBlock(
        id: csesDocumentBodyBlockId,
        blockType: ParagraphBlockKeys.type,
        text: '',
      ),
    );
  }
  return List<CollabEditorBlock>.unmodifiable([cover, title, ...body]);
}
