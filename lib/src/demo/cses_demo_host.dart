import 'package:cses_common/network/websocket/cses_websocket_client.dart';
import 'package:cses_common/network/websocket/websocket_init_entry.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/session/user.dart';

/// 独立 Demo 的应用级 CSES 主连接宿主，直接使用登录流程初始化的 Common 上下文。
///
/// 不解析登录响应或覆盖身份、连接地址。编辑器释放只注销路由，退出账号由此关闭
/// Demo 拥有的唯一主连接；必须先等待文档宿主关闭，再开始下一次登录。
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/cses_demo_host.dart';
///
/// const host = CsesDemoHost();
/// // 登录已完成，文档会话已注册。
/// await host.connect();
/// // 先等待文档会话释放。
/// host.close();
/// ```
final class CsesDemoHost {
  /// 创建主连接宿主；不自动登录或连接。
  const CsesDemoHost();

  /// 使用 Common 当前认证启动 CSES scope；Future 仅表示初始化已调度。
  ///
  /// 就绪由连接事件通知，不启用 IM；设备或登录上下文缺失时拒绝启动。
  Future<void> connect() {
    if (ctx.deviceId == null ||
        ctx.deviceId!.trim().isEmpty ||
        ctx.cookieId == null ||
        ctx.cookieId!.trim().isEmpty ||
        (User().userId ?? '').trim().isEmpty ||
        User().companyId.trim().isEmpty ||
        (ctx.websocketHost ?? '').trim().isEmpty) {
      throw const FormatException('登录上下文已失效，请重新登录');
    }
    return WebSocketInitEntry.initCses(source: 'mobile_collab_demo');
  }

  /// 前台恢复主连接，Future 最多等待 Common 默认 8 秒；false 表示尚未 ready。
  /// 允许 Common 在其重连窗口耗尽时恢复，不自行创建第二条物理连接。
  Future<bool> recover() => WebSocketInitEntry.ensureConnectedForRealtime(
    scope: WebSocketInitScope.cses,
    source: 'mobile_collab_demo_resume',
  );

  /// 先关闭主连接，再通过 Common 清理用户态；调用前必须 await 文档会话释放。
  ///
  /// 保留应用级设备信息，下一次 HTTP 登录和 WS 继续复用 Common 的设备身份。
  void close() {
    csesWebSocketClient.close();
    User().clearData();
  }
}
