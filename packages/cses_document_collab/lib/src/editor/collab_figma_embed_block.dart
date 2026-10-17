import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'collab_resource_block_base.dart';
import 'collab_web_block_base.dart';

/// Figma的独立节点构建器，复用网页校验和卡片外壳。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_figma_embed_block.dart';
/// final builders = {'figma-embed': CollabFigmaEmbedBlockComponentBuilder()};
/// // 将 builders 合并到 AppFlowyEditor.blockComponentBuilders。
/// ```
class CollabFigmaEmbedBlockComponentBuilder extends CollabWebBlockComponentBuilderBase {
  /// 创建不持有连接或平台视图的Figma构建器。
  CollabFigmaEmbedBlockComponentBuilder();

  /// 当前构建器只注册到 `figma-embed` 节点。
  @override
  String get blockType => 'figma-embed';

  /// 使用借用的 [context] 创建Figma，保持节点身份与编辑器配置。
  @override
  BlockComponentWidget buildWebBlock(BlockComponentContext context) =>
      _FigmaEmbedBlock(key: context.node.key, node: context.node, configuration: configuration);
}

/// 借用Figma节点，内容组件持有自身的网络或平台资源。
class _FigmaEmbedBlock extends CollabResourceBlock {
  /// [key] 控制状态复用；[node] 与 [configuration] 借用编辑器数据及配置。
  const _FigmaEmbedBlock({super.key, required super.node, required super.configuration});

  /// 创建Figma状态；不在构造阶段启动请求。
  @override
  createState() => _FigmaEmbedBlockState();
}

/// Figma类型的独立状态，复用原选区、菜单及布局算法。
class _FigmaEmbedBlockState extends CollabEmbeddedWebBlockState<_FigmaEmbedBlock> {
  /// 使用既有本地类型名称，不写回共享属性。
  @override
  String get resourceLabel => 'Figma';

  /// 使用Lucide钢笔标识设计内容，不引入Figma品牌Logo。
  @override
  IconData get webIcon => LucideIcons.penTool;
}
