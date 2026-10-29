import 'package:cses_common/cses_common_network.dart';
import 'package:cses_document_collab/cses_document_collab.dart';

/// 借用 Common 主连接的协同适配器，只拥有自身页面登记，不创建或关闭物理连接。
///
/// 可等待登记保证监听已安装；平台订阅及重连恢复统一由 Common 负责。
/// 所有本适配器消息采用即时发送，离线或同步发送失败不入队。
/// 协同会话负责发送离开及取消订阅，本适配器注销只释放本地登记。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/common_cses_collab_gateway.dart';
/// Future<void> useGateway() async {
///   final gateway = CommonCsesCollabGateway();
///   await gateway.register(pageId: 'demo-editor', documentId: 'existing-doc',
///     instanceId: 'unique-editor', callbacks: {'collabSync': (body) {}});
///   // 宿主先建立主连接，此处只示范空向量的协议封装。
///   gateway.send('demo-editor', 'collabJoin', {'stateVector': 'AA=='});
///   gateway.send('demo-editor', 'collabLeave', {});
///   gateway.send('demo-editor', 'unsubscribe', {});
///   await gateway.unregister('demo-editor');
/// }
/// ```
final class CommonCsesCollabGateway implements CsesCollabGateway {
  /// 创建页面登记适配器；主连接归宿主所有，每个pageId必须在活跃登记间唯一。
  CommonCsesCollabGateway();

  /// 本适配器发起的登记票据，隔离注销期间同名页面重开和迟到的注册失败。
  final Map<String, Object> _registrations = {};

  /// 查询当前 CSES hello-ready 状态，不发起连接。
  @override
  bool get isConnected => csesWebSocketClient.isConnected;

  /// 转发Common的hello-ready/离线事件；发布ready前Common已尝试恢复平台订阅。
  /// 多个监听者不会重复发送subscribe；发送失败时由即时发送前置返回false，协同会话有界重试。
  /// 按 ready 与连接代次组合去重，不能丢弃缺少中间离线通知的新连接 ready。
  @override
  Stream<bool> get connectionStates => WebSocketInitEntry.watch(scope: WebSocketInitScope.cses)
      .map((event) => (ready: event.current.isConnected, generation: csesWebSocketClient.connectionGeneration))
      .distinct()
      .map((state) => state.ready);

  /// 等待[pageId]的[documentId]/[instanceId]路由与[callbacks]安装，首次订阅正文为空Map。
  /// 离线也可完成本地登记；Common在hello-ready后恢复订阅，发送失败不入队。
  /// 重复活跃pageId抛StateError；注册被注销/关闭取消或安装失败时Future向调用方报告。
  @override
  Future<void> register({
    required String pageId,
    required String documentId,
    required String instanceId,
    required Map<String, void Function(Map<String, dynamic>)> callbacks,
  }) async {
    if (_registrations.containsKey(pageId)) throw StateError('协同页面已登记');
    final owner = Object();
    _registrations[pageId] = owner;
    try {
      await csesWebSocketClient.registerListenersAsync(
        pageId: pageId,
        subscription: SocketSubscription(channel: 'Document', topic: documentId, instance: instanceId),
        eventCallbacks: callbacks,
        params: const {},
        immediateOnly: true,
      );
    } catch (_) {
      if (identical(_registrations[pageId], owner)) _registrations.remove(pageId);
      rethrow;
    }
  }

  /// 即时发送[pageId]的[action]/[body]，未登记、离线或同步失败返回false且不入队。
  /// 普通命令前确保本代平台订阅已发送；leave/unsubscribe不为清理重新订阅。
  /// true仅表示本机发送调用成功，不表示服务端ACK或持久化。
  @override
  bool send(String pageId, String action, Map<String, dynamic> body) {
    if (!isConnected || !_registrations.containsKey(pageId)) return false;
    return csesWebSocketClient.trySendWithPage(
      pageId: pageId,
      action: action,
      body: body,
      ensureSubscribed: action != 'collabLeave' && action != 'unsubscribe',
    );
  }

  /// 等待[pageId]的本地监听、恢复登记及定时器注销，重复或非本适配器登记的页面直接完成。
  /// 立即撤销本适配器发送权限，不重复发送网络unsubscribe；主连接及其他页面保持。
  @override
  Future<void> unregister(String pageId) {
    if (_registrations.remove(pageId) == null) return Future<void>.value();
    return csesWebSocketClient.unregisterListenersAsync(pageId, localOnly: true);
  }
}
