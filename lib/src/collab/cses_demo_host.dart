import 'package:cses_common/network/websocket/cses_websocket_client.dart';
import 'package:cses_common/network/websocket/websocket_init_entry.dart';
import 'package:cses_common/runtime/config/config.dart';
import 'package:cses_common/runtime/config/env_type.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_common/runtime/device/device_util.dart';
import 'package:cses_common/runtime/preferences/sp_util.dart';
import 'package:cses_mobile_collab_demo/src/collab/cses_connection_settings.dart';

/// 独立 Demo 的应用级 CSES 主连接宿主；只导入已有登录会话，不执行登录 HTTP 流程。
///
/// 此对象拥有 Demo 进程唯一主连接。编辑器会话释放只注销路由，应用退出/切换账号由此关闭。
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/collab/cses_demo_host.dart';
/// import 'package:cses_mobile_collab_demo/src/collab/cses_connection_settings.dart';
/// import 'package:cses_mobile_collab_demo/src/collab/cses_doc_collaboration_session.dart';
/// Future<void> useHost(CsesConnectionSettings settings,
///     CsesDocCollaborationSession session) async {
///   const host = CsesDemoHost();
///   await host.configure(settings);
///   await session.start();
///   await host.connect();
///   // 编辑器生命周期结束后释放；会话不关闭共享主连接。
///   await session.dispose();
///   host.close();
/// }
/// ```
final class CsesDemoHost {
  /// 创建应用宿主；不自动连接或恢复凭证。
  const CsesDemoHost();

  /// 将已校验的 [settings] 写入 Common 内存上下文，不保存 cookie 或打印会话快照。
  ///
  /// 调用前必须释放旧会话并关闭旧主连接；Demo 固定使用 pre 环境标记和 bct appType，
  /// 实际地址取自表单，deviceId 通过 Common 设备工具读取并复用其缓存。
  Future<void> configure(CsesConnectionSettings settings) async {
    settings.validate();
    await SpUtil.getInstance();
    final deviceId = await DeviceUtils.getDeviceId();
    if (deviceId == null || deviceId.trim().isEmpty) {
      throw const FormatException('无法获取本机 deviceId，请检查设备后重试');
    }
    Config().appType = 'bct';
    Config().envType = EnvType.pre;
    ctx.websocketHost = settings.websocketUrl;
    ctx.cookieId = settings.cookieId;
    ctx.deviceId = deviceId;
    ctx.versionName = '1.0.0-collab-demo';
    ctx.versionCode = 1;
    ctx.osVersion = 'demo';
    // Common 会原样传递全部握手 Header；dart:io 不接受 null Header 值。
    // 独立宿主尚未初始化设备探针时也必须给出非空 CPU 展示值。
    ctx.cpuVersion = 'unknown';
    User().companyId = settings.companyId;
    User().userId = settings.userId;
  }

  /// 启动 CSES scope；Future 仅表示初始化已调度，就绪由连接事件通知，不启用 IM。
  Future<void> connect() =>
      WebSocketInitEntry.initCses(source: 'mobile_collab_demo');

  /// 前台恢复主连接，Future 最多等待 Common 默认 8 秒；false 表示尚未 ready。
  /// 允许 Common 在其重连窗口耗尽时恢复，不自行创建第二条物理连接。
  Future<bool> recover() => WebSocketInitEntry.ensureConnectedForRealtime(
    scope: WebSocketInitScope.cses,
    source: 'mobile_collab_demo_resume',
  );

  /// 应用退出或切换会话时关闭本宿主拥有的主连接并清除内存凭证。
  ///
  /// 必须先 await 文档协同会话释放，避免注册清理与下一次连接相互覆盖。
  void close() {
    csesWebSocketClient.close();
    ctx.cookieId = null;
    ctx.deviceId = null;
    User().userId = null;
    User().companyId = '';
  }
}
