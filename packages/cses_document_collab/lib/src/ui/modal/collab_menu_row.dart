import 'package:cses_document_collab/src/ui/modal/collab_row_content.dart';
import 'package:flutter/material.dart';

/// 基于 Row 的整行菜单操作，支持键盘激活与合并的按钮语义。
/// 需要 Material 祖先绘制点击反馈；不拥有业务状态或资源。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_menu_row.dart';
/// import 'package:cses_document_collab/src/ui/modal/collab_modal_theme.dart';
/// import 'package:flutter/material.dart';
/// Widget menu(VoidCallback open) => Material(
///   child: CollabModalTheme(
///     child: CollabMenuRow(title: const Text('打开'), onTap: open),
///   ),
/// );
/// ```
class CollabMenuRow extends StatelessWidget {
  /// [key] 控制组件身份与状态复用；[title] 为必需且允许换行的名称。
  /// [leading]、[subtitle]、[trailing] 默认不显示，分别为前置装饰、说明和尾部标记。
  /// [enabled] 默认 true；false 或 [onTap] 为 null 时禁止整行点击及键盘激活。
  /// [selected] 为可选的持久选中状态；null 表示普通动作，不声明选中语义。
  /// [onTap] 在整行激活时调用，业务异步错误由调用方处理。
  /// [iconColor]、[textColor] 为可选的可用态颜色，默认沿用弹窗主题；禁用态使用宿主禁用色。
  const CollabMenuRow({
    super.key,
    required this.title,
    this.leading,
    this.subtitle,
    this.trailing,
    this.enabled = true,
    this.selected,
    this.onTap,
    this.iconColor,
    this.textColor,
  });

  /// 必需名称，随系统文字缩放换行。
  final Widget title;

  /// 可选前置装饰，默认不显示；不应包含独立交互。
  final Widget? leading;

  /// 可选说明，默认不显示，允许多行。
  final Widget? subtitle;

  /// 可选尾部状态标记，默认不显示；整行统一接收激活事件。
  final Widget? trailing;

  /// 调用方控制的可用状态，默认 true；仍须提供 onTap 才可激活。
  final bool enabled;

  /// 可选的持久选中状态，由调用方持有；null 时不声明选中语义。
  final bool? selected;

  /// 整行激活回调；null 时禁用，回调及其业务资源由调用方持有。
  final VoidCallback? onTap;

  /// 可用态图标颜色，null 时使用弹窗默认色。
  final Color? iconColor;

  /// 可用态标题颜色，null 时使用弹窗默认色。
  final Color? textColor;

  /// 按借用 [context] 的密度和主题构建整行点击区，禁用时移除焦点与激活能力。
  @override
  Widget build(BuildContext context) {
    final active = enabled && onTap != null;
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: active,
        selected: selected,
        child: InkWell(
          onTap: active ? onTap : null,
          canRequestFocus: active,
          borderRadius: BorderRadius.circular(10),
          child: CollabRowContent(
            title: title,
            leading: leading,
            subtitle: subtitle,
            trailing: trailing,
            enabled: active,
            iconColor: iconColor,
            textColor: textColor,
          ),
        ),
      ),
    );
  }
}
