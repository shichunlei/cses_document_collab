import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'collab_table_controls.dart';

/// 独立渲染表格节点，布局、正文和协同状态由编辑器持有。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_table_block.dart';
/// final builder = CollabTableBlockComponentBuilder();
/// // 将 builder 注册到 AppFlowyEditor 的对应节点类型。
/// ```
class CollabTableBlockComponentBuilder extends BlockComponentBuilder {
  /// 创建不持有控制器或连接的表格构建器。
  CollabTableBlockComponentBuilder();

  /// 沿用结构节点无 Delta 的校验，结构完整性由原生层负责。
  @override
  BlockComponentValidate get validate =>
      (node) => node.delta == null;

  /// 根据借用的 [context] 创建表格视图，不取得编辑器资源所有权。
  @override
  BlockComponentWidget build(BlockComponentContext context) => _TableBlock(
    key: context.node.key,
    node: context.node,
    configuration: configuration,
  );
}

/// 借用编辑器及节点呈现表格，不创建输入或滚动控制器。
class _TableBlock extends BlockComponentStatelessWidget {
  /// [key] 控制身份复用；[node] 为借用节点；[configuration] 为编辑器配置。
  const _TableBlock({
    super.key,
    required super.node,
    required super.configuration,
  });

  /// 在 [context] 下呈现原有表格内容和操作，保留子块自己的输入代理。
  @override
  Widget build(BuildContext context) {
    final editor = context.read<EditorState>();
    return CollabTableControls(
      editor: editor,
      table: node,
      cellBuilder: (context, cell) => editor.renderer.build(context, cell),
    );
  }
}
