import 'package:cses_common/runtime/context/context.dart';
import 'package:flutter/material.dart';

/// 通过 Common 当前上下文解析 [userId] 的头像地址，不发起图片请求。
///
/// [userId] 为 null 或空字符串时使用 `ctx.faceDomain/default.jpg`；以 `http`
/// 开头的值原样返回；其他值直接拼接为 `ctx.faceDomain/userId/userId.jpg`，并附加
/// `t=ctx.timestamp.millisecondsSinceEpoch` 缓存参数，不修剪或编码用户 ID。
/// 默认头像分支依赖已初始化的 faceDomain，普通 ID 分支还依赖 timestamp；
/// Common 上下文未就绪时可能抛出 LateInitializationError。
/// 当前 Common 实现始终返回字符串，本函数沿用可空返回类型供展示层使用。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/mention_avatar.dart';
///
/// // Common 登录上下文初始化后调用，域名和缓存时间戳由 Common 提供。
/// final url = demoMentionAvatarUrl('999');
/// final defaultUrl = demoMentionAvatarUrl(null);
/// ```
String? demoMentionAvatarUrl(String? userId) => ctx.faceUri(userId);

/// 人员圆形头像，默认通过 Common 上下文解析头像地址；加载中或失败显示姓名首字。
/// 图片监听和缓存由Flutter管理，本组件不拥有连接，不把头像写入正文。
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_mobile_collab_demo/src/demo/mention_avatar.dart';
/// const avatar = DemoMentionAvatar(userId: '999', name: '测试员', size: 20);
/// // 由宿主用于行内提及、人员选择器或资料卡。
/// ```
class DemoMentionAvatar extends StatelessWidget {
  /// [key] 控制身份与状态复用，[userId] 为必填稳定用户ID，[name] 提供失败时的姓名首字。
  /// [size] 为正逻辑像素直径，默认36；[avatarUrl] 为宿主可选覆盖URL，null时交由 Common 解析 [userId]。
  const DemoMentionAvatar({super.key, required this.userId, required this.name, this.size = 36, this.avatarUrl})
    : assert(size > 0);

  /// 必填用户ID或以 http 开头的头像地址；不修剪，空字符串使用 Common 默认头像。
  final String userId;

  /// 必填显示名，空名称的回退为通用人员图标。
  final String name;

  /// 圆形直径，默认36逻辑像素；由调用方按所在行布局决定。
  final double size;

  /// 可选宿主头像URL；null时使用 Common 头像规则，失败时同样显示首字。
  final String? avatarUrl;

  /// 在借用 [context] 中提供固定尺寸圆形图片；回退不改变布局或无障碍姓名。
  @override
  Widget build(BuildContext context) {
    final url = avatarUrl ?? demoMentionAvatarUrl(userId);
    final fallback = ColoredBox(
      color: const Color(0xFFE0E7FF),
      child: Center(
        child: name.isEmpty
            ? Icon(Icons.person, size: size * .65)
            : Text(
                name.characters.first,
                style: TextStyle(fontSize: size * .5, color: const Color(0xFF3730A3)),
              ),
      ),
    );
    return ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size,
        child: ClipOval(
          child: url == null
              ? fallback
              : Image.network(
                  url,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  loadingBuilder: (_, child, progress) => progress == null ? child : fallback,
                  errorBuilder: (_, _, _) => fallback,
                ),
        ),
      ),
    );
  }
}

/// 通过公开头像契约构建Demo头像；[context] 借用当前位置，[userId]/[name] 为人员快照，
/// [size] 为逻辑像素边长，[avatarUrl] 为可选覆盖URL，null使用 Common 头像规则。
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// import 'package:cses_mobile_collab_demo/src/demo/mention_avatar.dart';
/// final services = CollabHostServices(mentionAvatarBuilder: buildDemoMentionAvatar);
/// ```
Widget buildDemoMentionAvatar(
  BuildContext context, {
  required String userId,
  required String name,
  required double size,
  String? avatarUrl,
}) => DemoMentionAvatar(userId: userId, name: name, size: size, avatarUrl: avatarUrl);
