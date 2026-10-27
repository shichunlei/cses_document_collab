import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/sync/cses_collab_gateway.dart';

/// 编辑器协同阶段；ready 只表示双向差量在本机完成并已提交发送，不代表数据库保存。
enum CsesCollabState { offline, syncing, ready, error }

/// 原始 Yrs 状态向量工厂；字节不包含 Base64 或 y-websocket 帧。
typedef CsesStateVectorFactory = Uint8List Function();

/// 应用 [update] 后，按 [serverVector] 返回服务端缺失的原始 V1 update。
typedef CsesSyncHandler =
    Uint8List Function(Uint8List update, Uint8List serverVector);

/// 应用原始远端正文或 Awareness [update]；不得将远端事件回发。
typedef CsesUpdateHandler = void Function(Uint8List update);

/// 生成本机 Awareness；[present] 为 false 时返回标准 null 删除状态。
typedef CsesAwarenessFactory = Uint8List Function(bool present);

/// 消费协同 [state]、稳定 [event] 名和可选 [error] 文案；不依赖保存回执。
typedef CsesSessionStateHandler =
    void Function(CsesCollabState state, String event, String? error);

/// 在共享 PaaS 主连接上管理一个 Document/docId/instance 的 Yrs 协同会话。
///
/// 本对象只拥有自己的监听、状态与定时器，不关闭主连接或业务 Doc。断线时保留 Yrs 状态，
/// 重连后重新 join，并以状态向量交换双向差量；离线不调用发送器，在线同步发送异常的队列语义由 Gateway 说明。
/// ```dart
/// import 'package:cses_document_collab/src/sync/cses_collab_gateway.dart';
/// import 'package:cses_document_collab/src/sync/cses_doc_collaboration_session.dart';
/// Future<void> useSession(CsesCollabGateway gateway, CsesStateVectorFactory encodeVector,
///     CsesSyncHandler applySync, CsesUpdateHandler applyUpdate,
///     CsesSessionStateHandler renderState) async {
///   final session = CsesDocCollaborationSession(
///     gateway: gateway, documentId: 'existing-doc',
///     instanceId: 'unique-editor', stateVectorFactory: encodeVector,
///     onSync: applySync, onUpdate: applyUpdate, onStateChanged: renderState,
///   );
///   await session.start();
///   // 宿主连接并收到 ready 后，由编辑器发送已持久化的本地 update。
///   await session.dispose();
/// }
/// ```
final class CsesDocCollaborationSession {
  /// 创建逻辑会话，不启动网络；状态向量、正文及 Awareness 由业务 Rust 引擎拥有。
  ///
  /// [gateway] 为借用主连接；[documentId] 是正式文档 ID；[instanceId] 在挂载期间稳定，
  /// 重挂载必须换新 ID。两者长度均为 1–128。[stateVectorFactory] 返回当前向量；
  /// [onSync] 同步应用差量并返回补传内容；[onUpdate] 仅应用远端正文；
  /// [onStateChanged] 由宿主展示状态及失败。[awarenessFactory]/[onAwareness] 同时提供时
  /// 启用在线成员同步，[onDisconnected] 负责清除远端显示，不销毁业务 Doc。
  /// [syncTimeout] 单轮默认 15 秒；[resyncInterval] 默认 20 秒；[awarenessInterval]
  /// 默认 10 秒，必须低于服务端 30 秒超时。[retryBaseDelay] 为有界退避基数，
  /// [maxRetries] 为 0–10，默认 3 次；[onStateChanged] 和其他回调不得销毁外部共享连接。
  CsesDocCollaborationSession({
    required this.gateway,
    required this.documentId,
    required this.instanceId,
    required this.stateVectorFactory,
    required this.onSync,
    required this.onUpdate,
    required this.onStateChanged,
    this.awarenessFactory,
    this.onAwareness,
    this.onDisconnected,
    this.syncTimeout = const Duration(seconds: 15),
    this.resyncInterval = const Duration(seconds: 20),
    this.awarenessInterval = const Duration(seconds: 10),
    this.retryBaseDelay = const Duration(milliseconds: 500),
    this.maxRetries = 3,
  }) {
    if (maxRetries < 0 ||
        maxRetries > 10 ||
        [
          syncTimeout,
          resyncInterval,
          awarenessInterval,
          retryBaseDelay,
        ].any((duration) => duration <= Duration.zero)) {
      throw ArgumentError('定时器间隔必须为正，maxRetries 范围为 0–10');
    }
    for (final id in [documentId, instanceId]) {
      if (id.trim().isEmpty || id.length > 128) {
        throw ArgumentError('docId 和 instance 必须非空且不超过 128 字符');
      }
    }
  }

  /// 借用主连接及平台订阅能力；本会话不关闭它。
  final CsesCollabGateway gateway;

  /// 正式测试文档 ID；不自动创建业务文档。
  final String documentId;

  /// 本次编辑器挂载的唯一实例 ID，物理重连期间保持稳定。
  final String instanceId;

  /// 获取当前原始状态向量。
  final CsesStateVectorFactory stateVectorFactory;

  /// 原子执行正文同步和反向差量计算。
  final CsesSyncHandler onSync;

  /// 应用远端 update，不回发。
  final CsesUpdateHandler onUpdate;

  /// 展示状态的单一出口；synced 消息不改变为数据库已保存。
  final CsesSessionStateHandler onStateChanged;

  /// 本机在线状态编码；null 表示暂不启用 Awareness。
  final CsesAwarenessFactory? awarenessFactory;

  /// 应用远端 Awareness；null 表示不显示在线成员。
  final CsesUpdateHandler? onAwareness;

  /// 断线时清除远端在线显示的业务回调。
  final void Function()? onDisconnected;

  /// 一轮握手超时，覆盖服务端房间释放等待及网络耗时。
  final Duration syncTimeout;

  /// 在线状态向量补偿周期。
  final Duration resyncInterval;

  /// 本机 Awareness 高时钟心跳周期，不替代物理 Socket 心跳。
  final Duration awarenessInterval;

  /// 自动重试退避的起始间隔。
  final Duration retryBaseDelay;

  /// 一轮连续失败允许的最大自动重试次数。
  final int maxRetries;

  StreamSubscription<bool>? _connectionSubscription;
  Timer? _syncTimer;
  Timer? _resyncTimer;
  Timer? _awarenessTimer;
  Timer? _retryTimer;
  bool _started = false;
  bool _registered = false;
  bool _disposed = false;
  bool _waitingSync = false;
  bool _terminal = false;
  int _retryCount = 0;
  CsesCollabState _state = CsesCollabState.offline;
  Future<void>? _disposeFuture;

  /// 本地注册 ID，不作为协议成员键；instance 才是线上路由的一部分。
  String get pageId => 'doc-collab-$instanceId';

  /// 当前协同阶段；与物理连接状态分离。
  CsesCollabState get state => _state;

  /// 注册本地接收及平台订阅；重复启动无副作用，关闭后不得再启动。
  ///
  /// Future 在本地注册完成后结束；在线时立即 join，离线时等主连接 ready 事件。
  Future<void> start() async {
    if (_disposed || _started) return;
    _started = true;
    _connectionSubscription = gateway.connectionStates.listen(
      _onConnectionChanged,
    );
    await gateway.register(
      pageId: pageId,
      documentId: documentId,
      instanceId: instanceId,
      callbacks: {
        'collabSync': (body) => _handle('collabSync', body),
        'collabUpdate': (body) => _handle('collabUpdate', body),
        'collabAwareness': (body) => _handle('collabAwareness', body),
        'collabSyncStatus': (body) => _handle('collabSyncStatus', body),
        'collabError': (body) => _handle('collabError', body),
        'collabClose': (body) => _handle('collabClose', body),
      },
    );
    if (_disposed) {
      await gateway.unregister(pageId);
      return;
    }
    _registered = true;
    if (gateway.isConnected) _beginSync(join: true);
  }

  /// 发送已持久化的本地 [update]；未 ready 时保留在 Yrs 中，由下一次差量同步补传。
  ///
  /// 返回 true 只表示立即发送成功；超限或发送失败退出 ready，Demo 不自行缓存旧命令；Common 同步发送失败可能入队。
  bool sendLocalUpdate(Uint8List update) {
    if (_disposed || _state != CsesCollabState.ready || update.isEmpty) {
      return false;
    }
    if (update.length > 1024 * 1024) {
      _fail('UPDATE_TOO_LARGE', '本地更新超过 1 MiB，内容已保留，请减少单次修改量', retry: false);
      return false;
    }
    if (!gateway.send(pageId, 'collabUpdate', {'data': base64Encode(update)})) {
      _fail('SEND_FAILED', '发送失败，本地修改已保留，正在重新同步', retry: true);
      return false;
    }
    return true;
  }

  /// 前台恢复时重新 join；保留权限、Schema 等终止错误，禁止自动绕过失败边界。
  void resync() {
    if (_disposed || _terminal || _waitingSync) return;
    _beginSync(join: true);
  }

  /// 用户主动重试；清除终止错误并重新 join，不替换文档或主连接。
  void retry() {
    if (_disposed) return;
    _terminal = false;
    _retryCount = 0;
    _cancelRound();
    _beginSync(join: true);
  }

  /// 消费主连接 [connected] 状态；Gateway 已在 ready 事件前恢复本实例的 subscribe。
  void _onConnectionChanged(bool connected) {
    if (_disposed || !_registered) return;
    if (!connected) {
      _cancelRound();
      _stopMaintenance();
      onDisconnected?.call();
      if (!_terminal) _emit(CsesCollabState.offline, 'socket-offline');
    } else if (!_terminal) {
      _retryCount = 0;
      _beginSync(join: true);
    }
  }

  /// 开始唯一一轮 [join] 或主动补偿；期间本地编辑保留于同一个 Doc，暂停实时上行。
  void _beginSync({required bool join}) {
    if (_disposed || _terminal || !_registered || _waitingSync) return;
    if (!gateway.isConnected) {
      _emit(CsesCollabState.offline, 'waiting-main-socket');
      return;
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    try {
      final vector = stateVectorFactory();
      if (vector.isEmpty || vector.length > 64 * 1024) {
        _fail('INVALID_STATE_VECTOR', '状态向量为空或超过 64 KiB', retry: false);
        return;
      }
      _waitingSync = true;
      final action = join ? 'collabJoin' : 'collabSync';
      _emit(CsesCollabState.syncing, action);
      if (!gateway.send(pageId, action, {
        'stateVector': base64Encode(vector),
      })) {
        _fail('SEND_FAILED', '握手发送失败，本地正文已保留', retry: true);
        return;
      }
      _syncTimer = Timer(syncTimeout, () {
        _fail('SYNC_TIMEOUT', '文档同步超时，请核对登录设备会话、正式 docId 和订阅路由', retry: true);
      });
    } catch (error, stackTrace) {
      _exception(error, stackTrace);
    }
  }

  /// 按精确 [action] 处理经过完整路由筛选的 [body]；未知字段允许扩展。
  void _handle(String action, Map<String, dynamic> body) {
    if (_disposed || _terminal || !gateway.isConnected) return;
    try {
      switch (action) {
        case 'collabSync':
          if (!_waitingSync) return;
          final update = _decode(body, 'data', 32 * 1024 * 1024);
          final vector = _decode(body, 'stateVector', 64 * 1024);
          final diff = onSync(update, vector);
          if (diff.isEmpty) {
            throw const FormatException('原始 V1 差量不能为空；空文档应编码为 [0, 0]');
          }
          if (diff.length > 1024 * 1024) {
            _fail(
              'UPDATE_TOO_LARGE',
              '补传差量超过 1 MiB，已保留本地内容，不能按字节拆包',
              retry: false,
            );
            return;
          }
          if (!gateway.send(pageId, 'collabUpdate', {
            'data': base64Encode(diff),
          })) {
            _fail('SEND_FAILED', '补传发送失败，等待重新同步', retry: true);
            return;
          }
          _cancelRound();
          _retryCount = 0;
          _emit(CsesCollabState.ready, 'bidirectional-sync-ready');
          _startMaintenance();
          _publishAwareness();
        case 'collabUpdate':
          onUpdate(_decode(body, 'data', 32 * 1024 * 1024));
        case 'collabAwareness':
          onAwareness?.call(_decode(body, 'data', 64 * 1024));
        case 'collabSyncStatus':
          // 此消息没有逐命令 requestId，不能用于首轮 ready 或数据库保存判断。
          onStateChanged(_state, 'sync-status-received', null);
        case 'collabClose':
          _fail('ROOM_CLOSED', '协同房间已关闭，正在重新加入', retry: true);
        case 'collabError':
          final code = body['code'];
          final retry = code == 'INTERNAL_ERROR';
          _fail(code is String ? code : 'UNKNOWN_ERROR', switch (code) {
            'DOCUMENT_NOT_FOUND' => '测试文档不存在，请先通过业务流程创建正式文档',
            'ACCESS_DENIED' => '文档访问被拒绝，请检查权限',
            'INVALID_REQUEST' => '协同参数或编码被拒绝，已停止自动重试',
            'INTERNAL_ERROR' => '协同服务暂不可用，正在重试',
            _ => '收到未知协同错误，已保留本地正文',
          }, retry: retry);
      }
    } catch (error, stackTrace) {
      _exception(error, stackTrace);
    }
  }

  /// 校验 [body] 的 Base64 [key]，在编码前/解码后按 [limit] 字节限制控制内存。
  ///
  /// 返回原始字节；空值、非法 Base64 或超限抛出 FormatException，不进入 Yrs。
  Uint8List _decode(Map<String, dynamic> body, String key, int limit) {
    final value = body[key];
    if (value is! String ||
        value.isEmpty ||
        value.length > ((limit + 2) ~/ 3) * 4) {
      throw FormatException('无效或超限的 $key');
    }
    final result = base64Decode(value);
    if (result.isEmpty || result.length > limit) {
      throw FormatException('无效或超限的 $key');
    }
    return result;
  }

  /// 以 [code]/[message] 退出 ready；[retry] 只用于允许重同步的瞬时失败。
  void _fail(String code, String message, {required bool retry}) {
    if (_disposed) return;
    _cancelRound();
    _stopMaintenance();
    _terminal = !retry;
    _emit(CsesCollabState.error, code, message);
    if (!retry || !gateway.isConnected || _retryCount >= maxRetries) return;
    final delay = retryBaseDelay * (1 << _retryCount);
    _retryCount += 1;
    _retryTimer = Timer(delay, () => _beginSync(join: true));
  }

  /// 非预期 [error]/[stackTrace] 由此统一记录；Schema、初始化来源冲突和格式错误停止自动重试。
  void _exception(Object error, StackTrace stackTrace) {
    CollabDiagnostics.report(
      '文档协同处理失败',
      error: error,
      stackTrace: stackTrace,
      tag: 'DocCollab',
    );
    final incompatible = error.toString().contains(
      'UNSUPPORTED_DOCUMENT_SCHEMA',
    );
    final bootstrapConflict = error.toString().contains(
      'DOCUMENT_BOOTSTRAP_CONFLICT',
    );
    _fail(
      bootstrapConflict
          ? 'DOCUMENT_BOOTSTRAP_CONFLICT'
          : incompatible
          ? 'UNSUPPORTED_DOCUMENT_SCHEMA'
          : 'INVALID_RESPONSE',
      bootstrapConflict
          ? '服务端已有不同来源的初始正文，已停止写入并保留本地内容，请核对文档'
          : incompatible
          ? '文档结构不合法或缓存模型冲突，已停止写入并保留本地正文'
          : '协同数据解析失败，本地正文已保留',
      retry: false,
    );
  }

  /// 启动状态向量补偿和本机在线状态心跳，不重复启动主连接心跳或重连。
  void _startMaintenance() {
    _stopMaintenance();
    _resyncTimer = Timer.periodic(
      resyncInterval,
      (_) => _beginSync(join: false),
    );
    if (awarenessFactory != null && onAwareness != null) {
      _awarenessTimer = Timer.periodic(
        awarenessInterval,
        (_) => _publishAwareness(),
      );
    }
  }

  /// 上报本机更高时钟的在线状态；不回传远端 clientID，不把它当正文保存信号。
  void _publishAwareness() {
    if (_disposed ||
        _state != CsesCollabState.ready ||
        awarenessFactory == null ||
        onAwareness == null) {
      return;
    }
    try {
      final update = awarenessFactory!(true);
      if (update.isEmpty || update.length > 64 * 1024) {
        throw const FormatException('Awareness 超限');
      }
      if (!gateway.send(pageId, 'collabAwareness', {
        'data': base64Encode(update),
      })) {
        _fail('SEND_FAILED', '在线状态发送失败，等待重新同步', retry: true);
      }
    } catch (error, stackTrace) {
      _exception(error, stackTrace);
    }
  }

  /// 清除当前握手和重试定时器，不删除本地 Doc 或平台订阅。
  void _cancelRound() {
    _waitingSync = false;
    _syncTimer?.cancel();
    _syncTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// 取消本会话周期任务；物理主连接资源归应用宿主。
  void _stopMaintenance() {
    _resyncTimer?.cancel();
    _resyncTimer = null;
    _awarenessTimer?.cancel();
    _awarenessTimer = null;
  }

  /// 发布 [state]/[event] 和可选 [error]；销毁后禁止 UI 状态回写。
  void _emit(CsesCollabState state, String event, [String? error]) {
    if (_disposed) return;
    _state = state;
    onStateChanged(state, event, error);
  }

  /// 幂等释放会话；在线按 Awareness null、leave、unsubscribe 顺序发送，离线不排队。
  ///
  /// Future 在本地监听注销后结束；不保证服务端收到退出，不关闭主连接或业务 Doc。
  Future<void> dispose() => _disposeFuture ??= _dispose();

  /// 取消任务并注销路由；同步阻止迟到回调后再等待异步注销完成。
  Future<void> _dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelRound();
    _stopMaintenance();
    if (_registered && gateway.isConnected) {
      if (_state == CsesCollabState.ready && awarenessFactory != null) {
        try {
          gateway.send(pageId, 'collabAwareness', {
            'data': base64Encode(awarenessFactory!(false)),
          });
        } catch (error, stackTrace) {
          CollabDiagnostics.report(
            '文档在线状态退出失败',
            error: error,
            stackTrace: stackTrace,
            tag: 'DocCollab',
          );
        }
      }
      gateway.send(pageId, 'collabLeave', const {});
      gateway.send(pageId, 'unsubscribe', const {});
    }
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    await gateway.unregister(pageId);
    _registered = false;
  }
}
