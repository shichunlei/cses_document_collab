import 'package:cses_document_collab/src/editor/collab_block_lock_scope.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 为借用的[editor]、[node]、[child]添加轻量锁提示及普通正文的块操作入口。
/// 普通正文预留52像素块操作区；卡片标记由自身外框覆盖到右上角，模板锁不画额外标记。
Widget decorateCollabBlockLock(BuildContext context, EditorState editor, Node node, Widget child) {
  final locks = CollabBlockLocks.of(editor);
  if (locks == null || locks.userId.isEmpty || node.parent == null) return child;
  return ListenableBuilder(
    listenable: Listenable.merge([locks, editor.selectionNotifier, editor.editableNotifier]),
    child: child,
    builder: (context, body) {
      final value = locks.state(CollabBlockLocks.idOf(node));
      final selected = editor.selection?.start.path.equals(node.path) ?? false;
      final ordinary =
          node.delta != null && node.type != 'code' || const {'table', 'table-cell', 'unsupported'}.contains(node.type);
      final badge = value.explicit && !value.template;
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
        'code',
      }.contains(node.type);
      return CollabBlockLockScope(
        blockId: value.blockId,
        showBadge: badge,
        child: Stack(
          clipBehavior: headerCard ? Clip.none : Clip.hardEdge,
          children: [
            Padding(padding: ordinary ? const EdgeInsets.only(right: 52) : EdgeInsets.zero, child: body!),
            if (badge && !headerCard)
              Positioned(
                right: ordinary ? 33 : 42,
                top: ordinary ? 4 : 12,
                child: Tooltip(
                  key: ValueKey('block-lock-badge-${value.blockId}'),
                  message: '内容已锁定',
                  child: const Icon(LucideIcons.lockKeyhole, size: 13, color: Color(0xFF8A8F9C)),
                ),
              ),
            if (ordinary && (selected || value.locked))
              Positioned(
                right: 0,
                top: 0,
                child: CollabBlockMoreButton(editor: editor, node: node, protectSubtree: node.children.isNotEmpty),
              ),
          ],
        ),
      );
    },
  );
}
