import 'package:cses_document_collab/src/ui/modal/collab_menu_density.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:flutter/material.dart';

/// 菜单行与开关行共用的纯展示布局，不注册手势或持有状态。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_row_content.dart';
/// import 'package:flutter/material.dart';
/// const content = CollabRowContent(title: Text('说明'), enabled: true);
/// ```
class CollabRowContent extends StatelessWidget {
  /// [key] 控制组件身份与状态复用；[title] 为名称；[leading]、[subtitle]、[trailing] 为可选装饰、说明和尾部控件。
  /// [enabled] 控制默认配色；[iconColor] 和 [textColor] 仅覆盖可用态颜色。
  const CollabRowContent({
    super.key,
    required this.title,
    required this.enabled,
    this.leading,
    this.subtitle,
    this.trailing,
    this.iconColor,
    this.textColor,
  });

  /// 允许换行的名称，由调用方创建。
  final Widget title;

  /// 默认颜色是否使用可用态。
  final bool enabled;

  /// 可选前置装饰。
  final Widget? leading;

  /// 可选多行说明。
  final Widget? subtitle;

  /// 可选尾部控件，其手势由控件自身处理。
  final Widget? trailing;

  /// 可选的可用态图标色。
  final Color? iconColor;

  /// 可选的可用态标题色。
  final Color? textColor;

  /// 在借用 [context] 中将文字限制在剩余宽度，高度随文字增长而非固定裁剪。
  @override
  Widget build(BuildContext context) {
    final compact = CollabMenuDensity.compactOf(context);
    final c = CollabModalColors.of(context);
    final theme = Theme.of(context);
    final titleStyle = (theme.textTheme.bodyMedium ?? const TextStyle())
        .copyWith(
          fontSize: 13,
          height: 1.55,
          color: enabled ? textColor ?? c.text : theme.disabledColor,
        );
    final subtitleStyle = (theme.textTheme.bodySmall ?? const TextStyle())
        .copyWith(
          fontSize: 11,
          height: 1.55,
          color: enabled ? c.muted : theme.disabledColor,
        );
    return IconTheme.merge(
      data: IconThemeData(
        size: 19,
        color: enabled ? iconColor ?? c.muted : theme.disabledColor,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: compact ? 42 : 51),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 12,
            vertical: compact ? 9 : 4,
          ),
          child: Row(
            children: [
              if (leading != null) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 19),
                  child: leading,
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DefaultTextStyle(style: titleStyle, child: title),
                    if (subtitle != null)
                      DefaultTextStyle(style: subtitleStyle, child: subtitle!),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}
