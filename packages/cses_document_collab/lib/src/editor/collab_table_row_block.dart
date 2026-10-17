import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'collab_table_children.dart';

/// 独立渲染表格行节点，布局、正文和协同状态由编辑器持有。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_table_row_block.dart';
/// final builder = CollabTableRowBlockComponentBuilder();
/// // 将 builder 注册到 AppFlowyEditor 的对应节点类型。
/// ```
class CollabTableRowBlockComponentBuilder extends BlockComponentBuilder {
  /// 创建不持有控制器或连接的表格行构建器。
  CollabTableRowBlockComponentBuilder();

  /// 沿用结构节点无 Delta 的校验，结构完整性由原生层负责。
  @override
  BlockComponentValidate get validate =>
      (node) => node.delta == null;

  /// 根据借用的 [context] 创建表格行视图，不取得编辑器资源所有权。
  @override
  BlockComponentWidget build(BlockComponentContext context) => _TableRowBlock(
    key: context.node.key,
    node: context.node,
    configuration: configuration,
  );
}

/// 借用编辑器及节点呈现表格行，不创建输入或滚动控制器。
class _TableRowBlock extends BlockComponentStatelessWidget {
  /// [key] 控制身份复用；[node] 为借用节点；[configuration] 为编辑器配置。
  const _TableRowBlock({
    super.key,
    required super.node,
    required super.configuration,
  });

  /// 在 [context] 下呈现原有表格行内容和操作，保留子块自己的输入代理。
  @override
  Widget build(BuildContext context) {
    final editor = context.read<EditorState>();
    return buildCollabTableChildren(context, editor, node);
  }
}
