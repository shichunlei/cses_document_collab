import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/model/collab_columns.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// 渲染单列的真实子块，并提供受公共会话保护的列操作。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_column_block.dart';
/// final builder = CollabColumnBlockComponentBuilder();
/// // 将builder注册到AppFlowyEditor的column类型。
/// ```
class CollabColumnBlockComponentBuilder extends BlockComponentBuilder {
  /// 创建不拥有文档、输入代理或其他资源的列构建器。
  CollabColumnBlockComponentBuilder();

  /// 列只能包含真实子块，不能直接保存文字Delta。
  @override
  BlockComponentValidate get validate =>
      (node) => node.delta == null;

  /// 在借用[context]下创建列组件，子块继续使用各自的输入代理。
  @override
  BlockComponentWidget build(BlockComponentContext context) =>
      _ColumnBlock(key: context.node.key, node: context.node, configuration: configuration);
}

/// 单列纵向正文；资源、权限与历史由所属编辑器持有。
class _ColumnBlock extends BlockComponentStatelessWidget {
  /// [key]控制身份复用；[node]和[configuration]借自当前编辑器。
  const _ColumnBlock({super.key, required super.node, required super.configuration});

  /// 在[context]绘制真实子树和独立列操作；只读与预览由公共菜单隐藏入口。
  @override
  Widget build(BuildContext context) {
    final editor = context.read<EditorState>();
    final parent = node.parent;
    final id = node.attributes['cses_collab_block_id'] as String? ?? node.id;
    final parentId = parent?.attributes['cses_collab_block_id'] as String? ?? parent?.id;
    final index = parent?.children.toList().indexOf(node) ?? -1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (parent?.type == 'columns')
          Align(
            alignment: Alignment.centerRight,
            child: CollabBlockMoreButton(
              editor: editor,
              node: node,
              protectSubtree: true,
              actions: [
                if (parent!.children.length < 8)
                  (
                    label: '在右侧插入列',
                    key: ValueKey('column-add-$id'),
                    run: () async {
                      await editCollabColumns(editor, parentId!, 'add', columnId: id);
                    },
                  ),
                if (index > 0)
                  (
                    label: '向左移动',
                    key: ValueKey('column-left-$id'),
                    run: () async {
                      await editCollabColumns(editor, parentId!, 'left', columnId: id);
                    },
                  ),
                if (index < parent.children.length - 1)
                  (
                    label: '向右移动',
                    key: ValueKey('column-right-$id'),
                    run: () async {
                      await editCollabColumns(editor, parentId!, 'right', columnId: id);
                    },
                  ),
                (
                  label: '加宽此列',
                  key: ValueKey('column-widen-$id'),
                  run: () async {
                    await editCollabColumns(editor, parentId!, 'widen', columnId: id);
                  },
                ),
                (
                  label: '删除此列及内容',
                  key: ValueKey('column-remove-$id'),
                  run: () async {
                    await editCollabColumns(editor, parentId!, 'remove', columnId: id);
                  },
                ),
              ],
            ),
          ),
        for (final child in node.children) editor.renderer.build(context, child),
        if (node.children.isEmpty && canEditCollabNode(editor, node))
          TextButton(
            key: ValueKey('column-body-$id'),
            onPressed: () async {
              if (!canEditCollabNode(editor, node) || !identical(findCollabActionNode(editor, id), node)) return;
              await editor.apply(
                editor.transaction
                  ..insertNode(node.path + [0], paragraphNode())
                  ..afterSelection = Selection.single(path: node.path + [0], startOffset: 0),
                skipHistoryDebounce: true,
              );
            },
            child: const Text('添加正文'),
          ),
      ],
    );
  }
}
