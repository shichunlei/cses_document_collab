import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'collab_table_children.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/model/collab_table.dart';
import 'collab_table_sheet.dart';

/// 独立渲染单元格节点，布局、正文和协同状态由编辑器持有。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_table_cell_block.dart';
/// final builder = CollabTableCellBlockComponentBuilder();
/// // 将 builder 注册到 AppFlowyEditor 的对应节点类型。
/// ```
class CollabTableCellBlockComponentBuilder extends BlockComponentBuilder {
  /// 创建不持有控制器或连接的单元格构建器。
  CollabTableCellBlockComponentBuilder();

  /// 沿用结构节点无 Delta 的校验，结构完整性由原生层负责。
  @override
  BlockComponentValidate get validate =>
      (node) => node.delta == null;

  /// 根据借用的 [context] 创建单元格视图，不取得编辑器资源所有权。
  @override
  BlockComponentWidget build(BlockComponentContext context) => _TableCellBlock(
    key: context.node.key,
    node: context.node,
    configuration: configuration,
  );
}

/// 借用编辑器及节点呈现单元格，不创建输入或滚动控制器。
class _TableCellBlock extends BlockComponentStatelessWidget {
  /// [key] 控制身份复用；[node] 为借用节点；[configuration] 为编辑器配置。
  const _TableCellBlock({
    super.key,
    required super.node,
    required super.configuration,
  });

  /// 在 [context] 下呈现原有单元格内容和操作，保留子块自己的输入代理。
  @override
  Widget build(BuildContext context) {
    final editor = context.read<EditorState>();
    final children = buildCollabTableChildren(context, editor, node);
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

/// 将桌面 [value] 限制到移动端可读范围；非法数值使用 [fallback]，不写回数据。
double _dimension(dynamic value, double fallback) =>
    value is num && value.isFinite && value > 0
    ? value.toDouble().clamp(48, 480)
    : fallback;
