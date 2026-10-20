import 'package:cses_document_collab/src/ui/modal/collab_row_content.dart';
import 'package:flutter/material.dart';

/// 基于 Row 的开关设置行；仅 Switch 本身处理点击、拖动及键盘切换。
/// 标题和空白区域无点击事件；状态由调用方持有，组件不拥有资源。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_modal_theme.dart';
/// import 'package:cses_document_collab/src/ui/modal/collab_switch_row.dart';
/// import 'package:flutter/material.dart';
/// Widget setting(bool value, ValueChanged<bool> update) => CollabModalTheme(
///   child: CollabSwitchRow(
///     title: const Text('锁定'), value: value, onChanged: update,
///   ),
/// );
/// ```
class CollabSwitchRow extends StatelessWidget {
  /// [key] 控制组件身份与状态复用；[title] 为必需名称。
  /// [leading] 和 [subtitle] 为可选装饰和多行说明，默认不显示。
  /// [value] 为调用方持有的当前状态；[onChanged] 仅在开关本体激活时接收新值。
  /// [onChanged] 为 null 时禁用开关；业务异步完成及错误由调用方负责。
  const CollabSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.leading,
    this.subtitle,
  });

  /// 必需名称，作为开关的合并无障碍标签，文字本身不可点击。
  final Widget title;

  /// 必需当前状态，组件不自行更新，由调用方重建同步。
  final bool value;

  /// 必需的可空开关回调；null 禁用，整行不提供切换回调。
  final ValueChanged<bool>? onChanged;

  /// 可选前置装饰，默认不显示。
  final Widget? leading;

  /// 可选多行说明，默认不显示，文字本身不可点击。
  final Widget? subtitle;

  /// 在借用 [context] 中布局说明与独立 Switch，合并语义而不添加行级手势。
  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: CollabRowContent(
      title: title,
      leading: leading,
      subtitle: subtitle,
      trailing: Switch(value: value, onChanged: onChanged),
      enabled: onChanged != null,
    ),
  );
}
