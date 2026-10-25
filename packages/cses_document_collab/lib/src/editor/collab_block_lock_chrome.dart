import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/ui/modal/collab_block_lock_scope.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 为借用的[editor]、[node]、[child]添加轻量锁提示，不额外创建块操作入口。
/// [context]为块视图所在的构建上下文；资源继续由调用方持有。
/// 段落、标题、列表、引用及表格等普通正文不显示锁标，也不预留提示空间；
/// 锁定权限仍由[editor]的守卫保护。日期及资源卡片保留锁标，更多按钮由卡片自身提供，
/// 模板锁不画额外标记。
Widget decorateCollabBlockLock(
  BuildContext context,
  EditorState editor,
  Node node,
  Widget child,
) {
  final locks = CollabBlockLocks.of(editor);
  if (locks == null || locks.userId.isEmpty || node.parent == null) {
    return child;
  }
  return ListenableBuilder(
    listenable: locks,
    child: child,
    builder: (context, body) {
      final value = locks.state(CollabBlockLocks.idOf(node));
      final ordinary =
          node.delta != null && node.type != 'code' ||
          const {'table', 'table-cell', 'unsupported'}.contains(node.type);
      final badge = !ordinary && value.explicit && !value.template;
      final headerCard = const {
        'meeting',
        'task',
        'kr-list',
        'audio',
        'attachment',
        'bookmark',
        'embed',
        'figma-embed',
        'juejin-embed',
        'mermaid',
        'formula',
        'code',
        'callout',
        'image',
        'video',
        'date-card',
        'weather',
        'divider',
        'page-divider',
      }.contains(node.type);
      return CollabBlockLockScope(
        blockId: value.blockId,
        showBadge: badge,
        child: Stack(
          clipBehavior: headerCard ? Clip.none : Clip.hardEdge,
          children: [
            body!,
            if (badge && !headerCard)
              Positioned(
                right: 42,
                top: 12,
                child: Tooltip(
                  key: ValueKey('block-lock-badge-${value.blockId}'),
                  message: '内容已锁定',
                  child: const Icon(
                    LucideIcons.lockKeyhole,
                    size: 13,
                    color: Color(0xFF8A8F9C),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
