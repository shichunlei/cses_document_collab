import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/model/collab_table.dart';
import 'collab_table_controls.dart';
import 'collab_table_sheet.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// 将普通及合并表格呈现为横向滚动网格，提供单元格操作并保留正文输入与协同。
///
/// 行高按正文自然扩展，边缘操作条提供行列选择与拖动列宽；编辑器与节点均由调用方持有。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_table_block.dart';
///
/// final builders = {
///   for (final type in ['table', 'table-row', 'table-cell'])
///     type: CollabTableBlockComponentBuilder(),
/// };
/// // 将 builders 合并到 AppFlowyEditor.blockComponentBuilders。
/// ```
class CollabTableBlockComponentBuilder extends BlockComponentBuilder {
  /// 创建无自有资源的表格渲染器；布局及正文状态由编辑器持有。
  CollabTableBlockComponentBuilder();

  /// 校验表格结构节点无 Delta；原生层负责矩形及合并结构的完整性判断。
  @override
  BlockComponentValidate get validate =>
      (node) => node.delta == null;

  /// 将借用的 [context] 节点交给网格或单元格呈现，不持有编辑器资源。
  @override
  BlockComponentWidget build(BlockComponentContext context) => _TableBlock(
    key: context.node.key,
    node: context.node,
    configuration: configuration,
  );
}

/// 将桌面 [value] 限制到移动端可读范围；非法数值使用 [fallback]，不写回数据。
double _dimension(dynamic value, double fallback) =>
    value is num && value.isFinite && value > 0
    ? value.toDouble().clamp(48, 480)
    : fallback;

/// 借用节点及编辑器渲染子树，不创建输入、连接或滚动控制器。
class _TableBlock extends BlockComponentStatelessWidget {
  /// [key] 控制组件身份；[node] 为借用节点；[configuration] 为编辑器呈现配置。
  const _TableBlock({
    super.key,
    required super.node,
    required super.configuration,
  });

  /// 在 [context] 下构建网格及原有行列/单元格操作；正文保留自己的输入代理。
  @override
  Widget build(BuildContext context) {
    final editor = context.read<EditorState>();
    if (node.type == 'table') {
      return CollabTableControls(
        editor: editor,
        table: node,
        cellBuilder: (context, cell) => editor.renderer.build(context, cell),
      );
    }

    final children = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final child in node.children)
          editor.renderer.build(context, child),
        if (node.children.isEmpty && editor.editable)
          TextButton(
            onPressed: () async {
              if (editor.isDisposed ||
                  !editor.editable ||
                  node.parent == null) {
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
    if (node.type == 'table-row') return children;
    final vertical = collabTableLayout(node)['verticalAlign'];
    return Container(
      key: ValueKey('collab-table-cell-${node.id}'),
      constraints: BoxConstraints(
        minHeight: _dimension(collabTableLayout(node.parent)['height'], 60),
      ),
      alignment: vertical == 'bottom'
          ? Alignment.bottomLeft
          : vertical == 'middle'
          ? Alignment.centerLeft
          : Alignment.topLeft,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: parseCollabBlockColor(
          node.attributes[csesBlockBackgroundColorAttribute] as String?,
        ),
        border: Border.all(color: const Color(0xFFDADDE3), width: 0.5),
      ),
      child: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(right: editor.editable ? 18 : 0),
            child: children,
          ),
          if (editor.editable && node.parent?.parent?.type == 'table')
            Positioned(
              top: 0,
              right: 0,
              child: ExcludeFocus(
                child: SizedBox.square(
                  dimension: 22,
                  child: IconButton(
                    key: ValueKey(
                      'table-cell-options-${collabTableNodeId(node)}',
                    ),
                    tooltip: '单元格操作',
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    icon: const Icon(Icons.more_horiz),
                    onPressed: () async {
                      final table = node.parent?.parent;
                      if (table == null ||
                          !editor.editable ||
                          editor.isDisposed) {
                        return;
                      }
                      final area = collabTableRegions(table)
                          .where(
                            (a) =>
                                collabTableNodeId(a.node) ==
                                collabTableNodeId(node),
                          )
                          .firstOrNull;
                      if (area != null) {
                        // 面板异常通过框架事件边界上报，不创建后台写入。
                        await showCollabTableSheet(
                          context,
                          editor,
                          table,
                          area,
                        );
                      }
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
