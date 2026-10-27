import 'dart:math' as math;

import 'package:cses_document_collab/src/ui/modal/collab_modal_actions.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_header.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_theme.dart';
import 'package:flutter/material.dart';

/// 固定标题/操作区、中部独立滚动的共用底部弹窗，负责键盘和底部安全区。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_bottom_sheet.dart';
/// import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
/// import 'package:lucide_icons_flutter/lucide_icons.dart';
/// import 'package:flutter/material.dart';
/// Future<void> open(BuildContext context) => showCollabBottomSheet<void>(
///   context: context, builder: (_) => const CollabBottomSheet(
///     title: Text('修改标题'), icon: LucideIcons.type, child: TextField()));
/// ```
class CollabBottomSheet extends StatelessWidget {
  /// [key] 控制身份；[title]/[icon] 为标题及装饰；[child] 为内容，不要重复避让键盘。
  /// [subtitle] 为可选单行省略说明，[header] 为固定的附加控件，如分类切换。
  /// [leadingAction] 为可选左侧次要操作，默认不显示。
  /// [actions] 默认为空；[canClose] 默认 true，false 阻止系统返回和关闭按钮。
  /// [closeKey] 保留关闭入口；[scrollController] 为借用滚动控制器，不会被释放。
  /// [scrollKey] 是可选的滚动视口标识。
  /// [contentPadding] 默认左右20、下18；[expand] 默认 false，true 时正文填满剩余高度、操作区贴底。
  /// [scrollBody] 默认true，由外壳滚动正文；false时[child]获得有限高度并自行管理滚动。
  const CollabBottomSheet({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.subtitle,
    this.header,
    this.actions = const [],
    this.leadingAction,
    this.canClose = true,
    this.closeKey,
    this.scrollController,
    this.scrollKey,
    this.contentPadding = const EdgeInsets.fromLTRB(20, 0, 20, 5),
    this.expand = false,
    this.scrollBody = true,
  });

  /// 必需标题。
  final Widget title;

  /// 必需装饰图标。
  final IconData icon;

  /// 可选标题说明，最多一行，超出显示省略号。
  final String? subtitle;

  /// 内容区域；默认由外壳滚动，scrollBody=false时可在有限高度内使用惰性列表。
  final Widget child;

  /// 可选固定附加头部，内容自行管理分类状态。
  final Widget? header;

  /// 固定操作区，空列表隐藏底部分隔线。
  final List<Widget> actions;

  /// 可选的左侧次要操作，如删除；窄屏时右侧按钮独立换行。
  final Widget? leadingAction;

  /// 是否允许关闭；false 同时阻止系统返回。
  final bool canClose;

  /// 业务关闭按钮标识。
  final Key? closeKey;

  /// 借用的滚动控制器，由创建方释放。
  final ScrollController? scrollController;

  /// 可选的内容滚动视口标识，用于恢复既有操作入口。
  final Key? scrollKey;

  /// 滚动内容内边距。
  final EdgeInsetsGeometry contentPadding;

  /// 是否由滚动正文填满可用高度，适用于图库和添加内容面板；操作区保持在安全区上方。
  final bool expand;

  /// 是否由外壳滚动正文，默认true；false时只应用内容边距，由child拥有目录滚动资源。
  /// false不使用scrollController，scrollKey仅标识内容容器，不改变路由或固定头尾行为。
  final bool scrollBody;

  /// 基于 [context] 的实际约束限制高度，键盘留白只在本层计算一次。
  /// 展开模式让正文占满剩余空间，底部操作区不随内容长短浮动。
  @override
  Widget build(BuildContext context) {
    final c = CollabModalColors.of(context);
    final media = MediaQuery.of(context);
    return CollabModalTheme(
      child: PopScope(
        canPop: canClose,
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 120),
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final height = math.max(
                0.0,
                math.min(637.0, math.min(constraints.maxHeight, media.size.height * .9 - media.viewInsets.bottom)),
              );
              final compact = height < 360;
              return ConstrainedBox(
                constraints: BoxConstraints(maxHeight: height),
                child: Material(
                  color: c.surface,
                  clipBehavior: Clip.antiAlias,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                  child: Padding(
                    padding: EdgeInsets.only(bottom: math.max(compact ? 12 : 22, media.padding.bottom)),
                    child: Column(
                      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!compact)
                          Center(
                            child: Container(
                              width: 34,
                              height: 4,
                              margin: const EdgeInsets.only(top: 10, bottom: 5),
                              decoration: BoxDecoration(color: c.line, borderRadius: BorderRadius.circular(8)),
                            ),
                          ),
                        CollabModalHeader(
                          title: title,
                          icon: icon,
                          subtitle: subtitle,
                          canClose: canClose,
                          compact: compact,
                          closeKey: closeKey,
                        ),
                        ?header,
                        Flexible(
                          fit: expand ? FlexFit.tight : FlexFit.loose,
                          child: scrollBody
                              ? SingleChildScrollView(
                                  key: scrollKey,
                                  controller: scrollController,
                                  padding: contentPadding,
                                  child: child,
                                )
                              : Padding(key: scrollKey, padding: contentPadding, child: child),
                        ),
                        if (actions.isNotEmpty || leadingAction != null)
                          CollabModalActions(leading: leadingAction, children: actions),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
