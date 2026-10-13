import 'package:cses_common/network/websocket/cses_websocket_client.dart';
import 'package:cses_common/network/websocket/models/socket_subscribe_header.dart';
import 'package:cses_common/network/websocket/websocket_init_entry.dart';

/// 协同会话借用的主连接端口；编辑器只拥有自己的路由注册。
abstract interface class CsesCollabGateway {
  /// 主连接已完成协议 hello，而非仅完成底层握手。
  bool get isConnected;

  /// 平台订阅发送后的 ready/离线变化；消费者负责取消订阅。
  Stream<bool> get connectionStates;

  /// 登记 [pageId] 的 [documentId]/[instanceId] 路由与 [callbacks]。
  /// Future 在本地注册完成后结束，不表示服务端已接收或已 join。
  Future<void> register({
    required String pageId,
    required String documentId,
    required String instanceId,
    required Map<String, void Function(Map<String, dynamic>)> callbacks,
  });

  /// 发送 [pageId] 的 [action]/[body]，离线或同步发送失败返回 false。
  /// Common 的同步发送失败仍可能进入其队列；true 也不代表业务 ACK。
  bool send(String pageId, String action, Map<String, dynamic> body);

  /// 只解除 [pageId] 的本地监听；网络退出由会话发送。
  Future<void> unregister(String pageId);
}

/// 使用 Common 原有接口连接 CSES，不创建物理 Socket，不修改 Common。
///
/// onlyListen 注册接收回调，平台 subscribe 由此适配器在 ready 时发送，确保离线注销
/// 仅清理本地监听。Common 的 register/unregister 为 async void，借用其公开 lock
/// 等待已排入的注册操作完成。该兼容方式仅用于独立 Demo 的单编辑器会话。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/collab/cses_collab_gateway.dart';
/// Future<void> useGateway() async {
///   final gateway = CommonCsesCollabGateway();
///   await gateway.register(pageId: 'demo-editor', documentId: 'existing-doc',
///     instanceId: 'unique-editor', callbacks: {'collabSync': (body) {}});
///   // 宿主先建立主连接，此处只示范空向量的协议封装。
///   gateway.send('demo-editor', 'collabJoin', {'stateVector': 'AA=='});
///   await gateway.unregister('demo-editor');
/// }
/// ```
final class CommonCsesCollabGateway implements CsesCollabGateway {
  /// 创建单会话路由适配器；资源归主连接和调用方会话所有。
  CommonCsesCollabGateway();

  final Map<String, SocketSubscription> _routes = {};

  /// 查询当前 CSES hello-ready 状态，不发起连接。
  @override
  bool get isConnected => csesWebSocketClient.isConnected;

  /// 每次主连接 ready 时先恢复本适配器的 subscribe，再通知会话重新 join。
  ///
  /// 此流必须由单一会话订阅一次；多次订阅会重复发送平台 subscribe。
  @override
  Stream<bool> get connectionStates =>
      WebSocketInitEntry.watch(
        scope: WebSocketInitScope.cses,
      ).map((event) => event.current.isConnected).distinct().map((connected) {
        if (connected) {
          for (final pageId in _routes.keys.toList(growable: false)) {
            send(pageId, 'subscribe', const {});
          }
        }
        return connected;
      });

  /// 登记 [pageId]、[documentId]/[instanceId] 和 [callbacks]，在线时先发空 body subscribe。
  ///
  /// 使用 onlyListen 避免 Common 自动排队 unsubscribe；锁屏障保证回调已安装才开始握手。
  @override
  Future<void> register({
    required String pageId,
    required String documentId,
    required String instanceId,
    required Map<String, void Function(Map<String, dynamic>)> callbacks,
  }) async {
    final route = SocketSubscription(
      channel: 'Document',
      topic: documentId,
      instance: instanceId,
    );
    csesWebSocketClient.registerListeners(
      pageId: pageId,
      subscription: route,
      eventCallbacks: callbacks,
      onlyListen: true,
    );
    await csesWebSocketClient.lock.synchronized(() {
      _routes[pageId] = route;
      if (isConnected) send(pageId, 'subscribe', const {});
    });
  }

  /// 发送 [pageId]/[action]/[body] 的标准 CSES 信封；离线不调用 Common 发送器。
  ///
  /// 复用 sendMessageWithResult 保留立即发送结果。底层同步异常仍可能排队，这是原 Common
  /// API 的已知边界；协同会话以向量重同步修复正文，不能据此宣称严格无队列发送。
  @override
  bool send(String pageId, String action, Map<String, dynamic> body) {
    final route = _routes[pageId];
    if (!isConnected || route == null) return false;
    return csesWebSocketClient.sendMessageWithResult({
      'action': action,
      'header': route.toJson(),
      'subscription': route.toJson(),
      'body': body,
    });
  }

  /// 注销 [pageId] 的纯监听注册；不关闭主连接，不排队取消订阅。
  @override
  Future<void> unregister(String pageId) async {
    _routes.remove(pageId);
    csesWebSocketClient.unregisterListeners(pageId);
    await csesWebSocketClient.lock.synchronized(() {});
  }
}
