import 'package:flutter/material.dart';

/// 弹窗设计稿的亮/暗配色；只读取宿主亮度，不修改宿主主题。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
/// import 'package:flutter/material.dart';
/// Widget label(BuildContext context) =>
///   Text('说明', style: TextStyle(color: CollabModalColors.of(context).muted));
/// ```
class CollabModalColors {
  /// [dark] 为 true 时使用设计稿的暗色配对。
  const CollabModalColors({required this.dark});

  /// 宿主当前是否使用暗色主题。
  final bool dark;

  /// 从借用的 [context] 读取当前亮度，不持有上下文。
  static CollabModalColors of(BuildContext context) =>
      CollabModalColors(dark: Theme.of(context).brightness == Brightness.dark);

  /// 主操作及选中项的紫色。
  Color get accent => Color(dark ? 0xFFB0A5FF : 0xFF6558D9);

  /// 主操作按钮上的文字色。
  Color get onAccent => Color(dark ? 0xFF231751 : 0xFFFFFFFF);

  /// 图标底色、选中背景及提示区域。
  Color get soft => Color(dark ? 0xFF302947 : 0xFFF0EDFF);

  /// 不透明的弹窗表面。
  Color get surface => Color(dark ? 0xFF202126 : 0xFFFFFFFF);

  /// 标题及正文文字。
  Color get text => Color(dark ? 0xFFEEEEF5 : 0xFF242633);

  /// 说明、占位及未选中图标。
  Color get muted => Color(dark ? 0xFFA9AAB9 : 0xFF757888);

  /// 分隔线、输入框边线及拖动条。
  Color get line => Color(dark ? 0xFF383941 : 0xFFECECF2);

  /// 输入框及次要操作背景。
  Color get field => Color(dark ? 0xFF292A32 : 0xFFF8F8FB);

  /// 删除及错误提示。
  Color get danger => Color(dark ? 0xFFFF94A4 : 0xFFCC4E62);

  /// 模态遮罩，锚点菜单不使用它。
  Color get barrier => Color(dark ? 0x94090B12 : 0x63222437);
}
