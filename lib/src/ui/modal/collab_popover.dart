import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_theme.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 锚点菜单共用表面，定位仍由业务负责。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_popover.dart';
/// import 'package:flutter/material.dart';
/// const menu = CollabPopover(title: '列操作', child: Text('插入列'));
/// ```
class CollabPopover extends StatelessWidget {
  /// [key] 控制身份；[title] 为菜单标题；[child] 为菜单内容；[width] 默认265逻辑像素。
  const CollabPopover({super.key, required this.title, required this.child, this.width = 265});

  /// 菜单标题。
  final String title;

  /// 菜单内容，拥有自身选择逻辑。
  final Widget child;

  /// 首选宽度，仍受外层定位约束限制。
  final double width;

  /// 按 [context] 的亮度应用13像素圆角、7像素内边距及阴影。
  @override
  Widget build(BuildContext context) {
    final c = CollabModalColors.of(context);
    return CollabModalTheme(
      compactList: true,
      child: Material(
        color: c.surface,
        elevation: 8,
        shadowColor: const Color(0x331C1834),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(13),
          side: BorderSide(color: c.line),
        ),
        child: SizedBox(
          width: width,
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(LucideIcons.x, size: 16),
                      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
                Flexible(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
