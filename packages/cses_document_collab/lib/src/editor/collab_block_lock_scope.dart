import 'package:flutter/widgets.dart';

/// 向当前块的卡片外框传递本地锁标记；嵌套块会建立自己的作用域。
///
/// ```dart
/// import 'package:flutter/widgets.dart';
/// import 'package:cses_document_collab/src/editor/collab_block_lock_scope.dart';
/// const scope = CollabBlockLockScope(blockId: 'card', showBadge: true, child: SizedBox());
/// ```
class CollabBlockLockScope extends InheritedWidget {
  /// [key]控制身份，[blockId]为稳定块身份，[showBadge]仅显式普通锁为true；
  /// [child]为借用的原块视图，不更改其布局或资源所有权。
  const CollabBlockLockScope({super.key, required this.blockId, required this.showBadge, required super.child});

  /// 当前块身份，供测试及语义标记使用。
  final String blockId;

  /// 是否在块自身的卡片右上角显示锁图标；模板锁及继承锁不重复显示。
  final bool showBadge;

  /// 从借用[context]订阅最近块的标记状态，无块作用域时返回null。
  static CollabBlockLockScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CollabBlockLockScope>();

  /// 对比借用[oldWidget]，只在身份或标记状态变化时刷新卡片外框。
  @override
  bool updateShouldNotify(CollabBlockLockScope oldWidget) =>
      blockId != oldWidget.blockId || showBadge != oldWidget.showBadge;
}
