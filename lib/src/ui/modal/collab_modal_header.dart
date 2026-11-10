import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 带图标、标题、说明和关闭入口的共用面板头；不拥有资源。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_modal_header.dart';
/// import 'package:lucide_icons_flutter/lucide_icons.dart';
/// import 'package:flutter/material.dart';
/// const heading = CollabModalHeader(title: Text('修改标题'), icon: LucideIcons.type);
/// ```
class CollabModalHeader extends StatelessWidget {
  /// [key] 控制身份；[title] 必填；[icon] 为紫色图标槽中的图标。
  /// [subtitle] 为可选单行说明，超长省略；[canClose] 默认 true；[closeKey] 保留业务关闭入口标识。
  /// [compact] 默认 false，键盘遮挡较多时压缩头部；[titleSize] 默认为18逻辑像素。
  const CollabModalHeader({
    super.key,
    required this.title,
    required this.icon,
    this.subtitle,
    this.canClose = true,
    this.closeKey,
    this.compact = false,
    this.titleSize = 18,
  });

  /// 必需标题，使用设计稿的半粗体及配置字号。
  final Widget title;

  /// 必需装饰图标，不产生独立无障碍描述。
  final IconData icon;

  /// 可选的11像素单行说明文字，超出可用宽度时显示省略号。
  final String? subtitle;

  /// 是否允许点击关闭，保存期间可设为 false。
  final bool canClose;

  /// 可选的关闭按钮身份，便于消费者定位原有入口。
  final Key? closeKey;

  /// 键盘挤压空间时压缩头部留白并隐藏副标题，默认 false。
  final bool compact;

  /// 标题基础字号，默认18，居中弹窗使用17；仍遵循系统文字缩放。
  final double titleSize;

  /// 按 [context] 构建固定头部；标题允许换行以适配大字和窄屏。
  /// 说明文字始终单行省略，避免长链接挤占操作内容的可用高度。
  @override
  Widget build(BuildContext context) {
    final c = CollabModalColors.of(context);
    return Padding(
      padding: compact ? const EdgeInsets.fromLTRB(16, 4, 16, 6) : const EdgeInsets.fromLTRB(20, 14, 20, 16),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.soft, borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: c.accent, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DefaultTextStyle.merge(
                  style: TextStyle(
                    fontSize: titleSize,
                    height: 1.55,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -.3,
                    color: c.text,
                  ),
                  child: title,
                ),
                if (subtitle != null && !compact)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      subtitle!,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, height: 1.55, color: c.muted),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            key: closeKey,
            tooltip: '关闭',
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            padding: EdgeInsets.zero,
            onPressed: canClose ? () => Navigator.pop(context) : null,
            icon: const Icon(LucideIcons.x, size: 19),
          ),
        ],
      ),
    );
  }
}
