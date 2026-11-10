import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:flutter/material.dart';

/// 卡片和弹窗标题共用的类型图标，按宿主主题亮度配色。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_type_icon.dart';
/// import 'package:lucide_icons_flutter/lucide_icons.dart';
///
/// const audioIcon = CollabTypeIcon(icon: LucideIcons.audioLines);
/// ```
class CollabTypeIcon extends StatelessWidget {
  /// [key] 控制组件身份；[icon] 指定必填的装饰图标。
  const CollabTypeIcon({super.key, required this.icon});

  /// 显示在圆角紫色底板上的图标，不产生独立的无障碍描述。
  final IconData icon;

  /// 从 [context] 读取亮暗主题，绘制固定尺寸的图标和底板。
  @override
  Widget build(BuildContext context) {
    final colors = CollabModalColors.of(context);
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.soft,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: colors.accent, size: 19),
    );
  }
}
