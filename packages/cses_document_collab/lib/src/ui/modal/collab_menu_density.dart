import 'package:flutter/material.dart';

/// 在弹窗子树传递菜单密度，嵌套弹窗可独立覆盖，不影响宿主主题。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_menu_density.dart';
/// import 'package:flutter/widgets.dart';
/// const scope = CollabMenuDensity(compact: true, child: SizedBox());
/// ```
class CollabMenuDensity extends InheritedWidget {
  /// [key] 控制组件身份与状态复用；[compact] 控制紧凑间距；[child] 为借用的菜单子树。
  const CollabMenuDensity({
    super.key,
    required this.compact,
    required super.child,
  });

  /// true 使用锚点菜单间距，false 使用常规底部菜单间距。
  final bool compact;

  /// 从借用 [context] 订阅最近的菜单密度；独立使用时默认常规间距。
  static bool compactOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<CollabMenuDensity>()
          ?.compact ??
      false;

  /// [oldWidget] 的密度变化时通知菜单行重新布局。
  @override
  bool updateShouldNotify(CollabMenuDensity oldWidget) =>
      compact != oldWidget.compact;
}
