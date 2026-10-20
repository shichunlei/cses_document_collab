import 'dart:math' as math;

import 'package:cses_document_collab/src/ui/modal/collab_modal_actions.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_header.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_theme.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 共用居中弹窗，与底部面板共享标题、输入及操作区样式。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_dialog.dart';
/// import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
/// import 'package:flutter/material.dart';
/// Future<void> open(BuildContext context) => showCollabDialog<void>(
///   context: context, builder: (_) => const CollabDialog(
///     title: Text('提示'), content: Text('操作已完成')));
/// ```
class CollabDialog extends StatelessWidget {
  /// [key] 控制身份；[title] 必填；[content] 为可选内容，不要重复套滚动区域。
  /// [leadingAction] 为可选左侧次要操作，默认不显示。
  /// [icon] 默认为信息图标；[actions] 默认为空；[canClose] 默认 true。
  const CollabDialog({
    super.key,
    required this.title,
    this.content,
    this.icon = LucideIcons.info,
    this.actions = const [],
    this.leadingAction,
    this.canClose = true,
  });

  /// 必需标题。
  final Widget title;

  /// 可选滚动正文。
  final Widget? content;

  /// 标题图标，默认信息符号。
  final IconData icon;

  /// 可换行的固定操作区。
  final List<Widget> actions;

  /// 可选的左侧次要操作，如删除；窄屏时右侧按钮独立换行。
  final Widget? leadingAction;

  /// 是否允许关闭，保存时可阻止按钮及系统返回。
  final bool canClose;

  /// 在 [context] 中按24像素外间距、20像素圆角渲染，保留系统键盘避让。
  @override
  Widget build(BuildContext context) {
    final c = CollabModalColors.of(context);
    return CollabModalTheme(
      child: PopScope(
        canPop: canClose,
        child: Dialog(
          insetPadding: const EdgeInsets.all(24),
          backgroundColor: c.surface,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 420,
              maxHeight: math.min(
                630,
                math.max(0, MediaQuery.sizeOf(context).height - MediaQuery.viewInsetsOf(context).bottom - 72),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: CollabModalHeader(title: title, icon: icon, canClose: canClose, titleSize: 17),
                ),
                if (content != null)
                  Flexible(
                    child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 16), child: content),
                  ),
                if (actions.isNotEmpty || leadingAction != null)
                  CollabModalActions(leading: leadingAction, bottom: 20, children: actions),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
