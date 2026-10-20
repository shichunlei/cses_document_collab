import 'package:cses_document_collab/src/ui/modal/collab_block_lock_scope.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 为标准卡片和自定义外框共用右上角锁标，不接管内容或编辑器资源。
/// 外边距应放在本组件外，内容圆角裁切应保留在[child]内。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_card_lock_overlay.dart';
/// import 'package:flutter/material.dart';
/// const card = CollabCardLockOverlay(child: SizedBox(width: 200, height: 80));
/// // 在编辑器的CollabBlockLockScope下使用，未锁定时不显示标记。
/// ```
class CollabCardLockOverlay extends StatelessWidget {
  /// [key]控制组件身份与状态复用；[child]是借用的实际卡片外框，不由本组件裁切。
  const CollabCardLockOverlay({super.key, required this.child});

  /// 必填实际外框；其内容、布局及资源始终由调用方持有。
  final Widget child;

  /// 从借用的[context]读取锁作用域；标记越过卡片右上角5逻辑像素且不拦截点击。
  @override
  Widget build(BuildContext context) {
    final lock = CollabBlockLockScope.maybeOf(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        if (lock?.showBadge == true)
          Positioned(
            top: -5,
            right: -5,
            child: IgnorePointer(
              child: Tooltip(
                key: ValueKey('block-lock-badge-${lock!.blockId}'),
                message: '内容已锁定',
                child: const Icon(
                  LucideIcons.lockKeyhole,
                  size: 14,
                  color: Color(0xFF87909E),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
