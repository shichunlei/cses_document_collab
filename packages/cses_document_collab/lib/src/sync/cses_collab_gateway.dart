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
