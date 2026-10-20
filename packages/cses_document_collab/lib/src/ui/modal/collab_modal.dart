import 'dart:math' as math;

import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_theme.dart';
import 'package:cses_document_collab/src/ui/modal/collab_popover.dart';
import 'package:flutter/material.dart';

/// 展示共用底部路由；取消返回 null，等待退场及子组件释放后返回结果。
/// [context] 提供导航和主题；[builder] 创建业务内容，不负责正文焦点恢复。
/// [requestFocus] 默认为 true；[useRootNavigator] 默认为 false，沿用编辑器所在导航器。
/// [isDismissible] 与 [enableDrag] 分别控制遮罩和下拉关闭，默认为 true。
/// 路由错误透传，业务控制器和服务始终由调用方持有。
Future<T?> showCollabBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool requestFocus = true,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
}) async {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final route = ModalBottomSheetRoute<T>(
    builder: (context) => CollabModalTheme(child: builder(context)),
    capturedThemes: InheritedTheme.capture(from: context, to: navigator.context),
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    modalBarrierColor: CollabModalColors.of(context).barrier,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showDragHandle: false,
    requestFocus: requestFocus,
  );
  final result = await navigator.push(route);
  await route.completed;
  return result;
}

/// 展示共用居中路由并等待完整退场；取消返回 null，导航异常透传。
/// [context] 提供主题和导航；[builder] 创建业务弹窗。
/// [useRootNavigator] 默认 true，保持既有 showDialog 的导航层级；
/// [requestFocus] 默认 true；[barrierDismissible] 默认 true。
/// 调用方负责编辑器操作会话，不能在 builder 内释放借用的业务资源。
Future<T?> showCollabDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useRootNavigator = true,
  bool requestFocus = true,
  bool barrierDismissible = true,
}) async {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final route = DialogRoute<T>(
    context: context,
    builder: (context) => CollabModalTheme(child: builder(context)),
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    barrierColor: CollabModalColors.of(context).barrier,
    barrierDismissible: barrierDismissible,
    requestFocus: requestFocus,
  );
  final result = await navigator.push(route);
  await route.completed;
  return result;
}

/// 在 [context] 对应组件下方打开锚点菜单，空间不足时翻到上方。
/// [title] 是菜单标题；[builder] 创建业务内容；[requestFocus] 默认 false。
/// [width] 为首选宽度，默认265逻辑像素，实际宽度受屏幕安全区与键盘约束。
/// 使用最近 Navigator，捕获原主题；取消返回 null，退场后返回结果。
/// 找不到有效的锚点时直接返回 null，不修改正文输入或业务状态。
Future<T?> showCollabPopover<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  bool requestFocus = false,
  double width = 265,
}) async {
  final navigator = Navigator.of(context);
  final box = context.findRenderObject() as RenderBox?;
  final overlay = navigator.overlay?.context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null || !box.attached) return null;
  final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  final direction = Directionality.of(context);
  final route = RawDialogRoute<T>(
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    transitionDuration: const Duration(milliseconds: 100),
    requestFocus: requestFocus,
    pageBuilder: (context, _, _) {
      final media = MediaQuery.of(context);
      return themes.wrap(
        CustomSingleChildLayout(
          delegate: _CollabPopoverLayout(
            anchor,
            direction,
            EdgeInsets.fromLTRB(
              media.padding.left + 8,
              media.padding.top + 8,
              media.padding.right + 8,
              math.max(media.viewInsets.bottom, media.padding.bottom) + 8,
            ),
          ),
          child: CollabPopover(title: title, width: width, child: builder(context)),
        ),
      );
    },
  );
  final result = await navigator.push(route);
  await route.completed;
  return result;
}

/// 保持菜单在安全区域和键盘之外的锚点布局，不拥有渲染对象。
class _CollabPopoverLayout extends SingleChildLayoutDelegate {
  /// [anchor] 为导航覆盖层坐标；[direction] 为文字方向；[insets] 为有效边缘留白。
  const _CollabPopoverLayout(this.anchor, this.direction, this.insets);

  /// 借用组件在导航覆盖层中的逻辑像素范围。
  final Rect anchor;

  /// 打开时的文字方向，决定菜单左右对齐。
  final TextDirection direction;

  /// 当前安全区和键盘之外的有效留白。
  final EdgeInsets insets;

  /// 按借用的父 [constraints] 给出不超过可视区域的松约束。
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints.loose(
    Size(math.max(0, constraints.maxWidth - insets.horizontal), math.max(0, constraints.maxHeight - insets.vertical)),
  );

  /// 根据父 [size] 与实际 [childSize] 翻转和限幅，不缓存过期布局。
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final right = math.max(insets.left, size.width - insets.right - childSize.width);
    final bottom = math.max(insets.top, size.height - insets.bottom - childSize.height);
    final left = direction == TextDirection.rtl ? anchor.right - childSize.width : anchor.left;
    final below = anchor.bottom + 8;
    return Offset(
      left.clamp(insets.left, right),
      (below <= bottom ? below : anchor.top - childSize.height - 8).clamp(insets.top, bottom),
    );
  }

  /// 比较借用的 [oldDelegate]，锚点、方向或安全区域变化时重新定位。
  @override
  bool shouldRelayout(_CollabPopoverLayout oldDelegate) =>
      anchor != oldDelegate.anchor || direction != oldDelegate.direction || insets != oldDelegate.insets;
}
