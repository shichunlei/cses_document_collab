import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:flutter/material.dart';

/// 可换行的固定操作区；不接管按钮的回调或加载状态。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_modal_actions.dart';
/// import 'package:flutter/material.dart';
/// const actions = CollabModalActions(children: [Text('完成')]);
/// ```
class CollabModalActions extends StatelessWidget {
  /// [key] 控制身份；[children] 为右侧按钮；[bottom] 默认为2逻辑像素。
  /// [leading] 为可选左侧次要操作，其资源和回调由调用方持有。
  const CollabModalActions({
    super.key,
    required this.children,
    this.bottom = 2,
    this.leading,
  });

  /// 按原始顺序向右排列的按钮，窄屏或大字时换行。
  final List<Widget> children;

  /// 底部留白，外壳另外负责安全区。
  final double bottom;

  /// 可选左侧次要操作，不加入右侧按钮组。
  final Widget? leading;

  /// 在 [context] 中构建细分隔线及10像素间距的操作区。
  /// 左侧操作按自然宽度布局且不超过可用宽度一半，右侧使用剩余空间并贴右排列。
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border(
        top: BorderSide(color: CollabModalColors.of(context).line),
      ),
    ),
    child: Padding(
      padding: EdgeInsets.fromLTRB(20, 14, 20, bottom),
      child: leading == null
          ? OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: 10,
              overflowSpacing: 8,
              children: children,
            )
          : LayoutBuilder(
              builder: (context, constraints) => Row(
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth / 2,
                    ),
                    child: leading!,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OverflowBar(
                      alignment: MainAxisAlignment.end,
                      overflowAlignment: OverflowBarAlignment.end,
                      spacing: 10,
                      overflowSpacing: 8,
                      children: children,
                    ),
                  ),
                ],
              ),
            ),
    ),
  );
}
