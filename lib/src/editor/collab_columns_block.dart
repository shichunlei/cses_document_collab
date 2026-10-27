import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/model/collab_columns.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// 渲染正式分栏树，保留列宽比例与各列的独立输入代理；窄屏横向滚动。
/// 每个视图独占builder，编辑器与节点由调用方持有。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_columns_block.dart';
/// final builder = CollabColumnsBlockComponentBuilder();
/// // 将builder注册到AppFlowyEditor的columns类型。
/// ```
class CollabColumnsBlockComponentBuilder extends BlockComponentBuilder {
  /// 创建不持有编辑器、连接或滚动控制器的构建器。
  CollabColumnsBlockComponentBuilder();

  /// 校验无正文的容器及直接列子块，非法结构交给错误构建器保留。
  @override
  BlockComponentValidate get validate =>
      (node) => node.delta == null && node.children.every((c) => c.type == 'column');

  /// 使用借用[context]建立分栏视图，保留节点的组件身份。
  @override
  BlockComponentWidget build(BlockComponentContext context) =>
      _ColumnsBlock(key: context.node.key, node: context.node, configuration: configuration);
}

/// 借用文档树绘制分栏和公共操作入口，不在布局过程中修复共享属性。
class _ColumnsBlock extends BlockComponentStatelessWidget {
  /// [key]控制组件身份；[node]与[configuration]由所属编辑器借出。
  const _ColumnsBlock({super.key, required super.node, required super.configuration});

  /// 在[context]保留横向比例和列内编辑，手机每列至少180逻辑像素。
  @override
  Widget build(BuildContext context) {
    final editor = context.read<EditorState>();
    final id = node.attributes['cses_collab_block_id'] as String? ?? node.id;
    final widths = collabColumnWidths(node);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: CollabBlockMoreButton(
            editor: editor,
            node: node,
            protectSubtree: true,
            actions: [
              if (node.children.length < 8)
                (
                  label: '添加一列',
                  key: ValueKey('columns-add-$id'),
                  run: () async {
                    await editCollabColumns(editor, id, 'add');
                  },
                ),
              (
                label: '平均分配列宽',
                key: ValueKey('columns-equal-$id'),
                run: () async {
                  await editCollabColumns(editor, id, 'equal');
                },
              ),
              (
                label: '转为上下排列',
                key: ValueKey('columns-flatten-$id'),
                run: () async {
                  await editCollabColumns(editor, id, 'flatten');
                },
              ),
            ],
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final minRatio = widths.isEmpty ? 1.0 : widths.reduce(math.min) / 100;
            final width = math.max(constraints.maxWidth, 180 / math.max(minRatio, .001));
            return SingleChildScrollView(
              key: PageStorageKey('columns-scroll-$id'),
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < node.children.length; i++)
                      SizedBox(
                        width: width * widths[i] / 100,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: editor.renderer.build(context, node.children[i]),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
