import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

/// 在 [context] 下使用借用的 [editor] 渲染 [node] 的正文子树。
///
/// 空行或单元格在可编辑时显示添加正文按钮；点击时重新检查编辑器与节点，
/// 等待插入事务及光标移动完成。编辑器和子块的资源仍由调用方持有。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_table_children.dart';
/// // context、editor 和 node 由当前块渲染上下文提供。
/// final body = buildCollabTableChildren(context, editor, node);
/// ```
Widget buildCollabTableChildren(
  BuildContext context,
  EditorState editor,
  Node node,
) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final child in node.children) editor.renderer.build(context, child),
      if (node.children.isEmpty && editor.editable)
        TextButton(
          onPressed: () async {
            if (editor.isDisposed || !editor.editable || node.parent == null) {
              return;
            }
            await editor.apply(
              editor.transaction
                ..insertNode(node.path + [0], paragraphNode())
                ..afterSelection = Selection.single(
                  path: node.path + [0],
                  startOffset: 0,
                ),
            );
          },
          child: const Text('添加正文'),
        ),
    ],
  );
}
