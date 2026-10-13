import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Demo 使用的已登录 CSES 会话快照；凭证仅驻留内存，不写入 SQLite；Common 自身的连接日志遵循其现有行为。
///
/// deviceId 由宿主通过 cses.common 自动读取，cookieId 使用有效登录会话。此类型不执行登录、不创建文档，
/// 也不把 companyId 当作文档授权。示例：
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/collab/cses_connection_settings.dart';
/// const settings = CsesConnectionSettings(
///   websocketUrl: 'wss://test.example/ws', cookieId: 'login-cookie',
///   companyId: 'login-company',
///   userId: 'login-user', documentId: 'existing-test-doc',
/// );
/// // 示例标识需替换为有效测试登录和正式测试文档 ID。
/// void validateSettings() => settings.validate();
/// ```
final class CsesConnectionSettings {
  /// 构造会话；参数取自目标环境和已有登录，设备 ID 不由调用方填写。
  ///
  /// [websocketUrl] 为包含部署路径的 ws/wss 完整地址；[cookieId] 为登录会话标识；
  /// [companyId]、[userId] 用于企业上下文及本地缓存隔离；
  /// [documentId] 是已创建的正式 BlockCraft 文档 ID，不是随意生成的房间名称。
  const CsesConnectionSettings({
    required this.websocketUrl,
    required this.cookieId,
    required this.companyId,
    required this.userId,
    required this.documentId,
  });

  /// 完整主连接地址；不能追加文档 ID 或旧 /collaboration 路径。
  final String websocketUrl;

  /// 登录会话凭证；调用方只在本机输入框及内存中持有。
  final String cookieId;

  /// 当前登录企业上下文；不代表文档权限。
  final String companyId;

  /// 当前用户 ID；用于 Awareness 展示及缓存隔离，不参与 WS 鉴权。
  final String userId;

  /// 服务端已存在的正式 BlockCraft 文档 ID，长度 1–128 字符。
  final String documentId;

  /// 校验输入；不访问网络。缺少会话或地址不合法时抛出 FormatException。
  void validate() {
    final uri = Uri.tryParse(websocketUrl);
    if (uri == null ||
        !const ['ws', 'wss'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.hasQuery) {
      throw const FormatException(
        '请输入不含 Query、凭证或 fragment 的 ws:// 或 wss:// 完整主连接地址',
      );
    }
    if ([cookieId, companyId, userId].any((value) => value.trim().isEmpty)) {
      throw const FormatException('请完整填写已有登录的 cookieId、companyId 和 userId');
    }
    if (documentId.trim().isEmpty || documentId.length > 128) {
      throw const FormatException('测试文档 ID 必须非空且不超过 128 字符');
    }
  }

  /// 以地址、企业、用户和文档隔离本地增量日志；不把 cookieId 或原始身份写进路径。
  ///
  /// 会话 cookie 轮换仍能恢复同一用户的离线修改；不同企业、用户或服务端不会合并缓存。
  /// BlockCraft 使用独立版本前缀，保留旧 Demo 缓存但不向正式正文混入旧私有结构。
  String get cacheDocumentId =>
      'cses-blockcraft-v1:${sha256.convert(utf8.encode(jsonEncode([websocketUrl, companyId, userId, documentId])))}';
}
