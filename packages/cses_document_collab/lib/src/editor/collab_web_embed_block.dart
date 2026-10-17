import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'collab_resource_block_base.dart';
import 'collab_web_block_base.dart';

/// 网页嵌入的独立节点构建器，复用网页校验和卡片外壳。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_web_embed_block.dart';
/// final builders = {'embed': CollabWebEmbedBlockComponentBuilder()};
/// // 将 builders 合并到 AppFlowyEditor.blockComponentBuilders。
/// ```
class CollabWebEmbedBlockComponentBuilder
    extends CollabWebBlockComponentBuilderBase {
  /// 创建不持有连接或平台视图的网页嵌入构建器。
  CollabWebEmbedBlockComponentBuilder();

  /// 当前构建器只注册到 `embed` 节点。
  @override
  String get blockType => 'embed';

  /// 使用借用的 [context] 创建网页嵌入，保持节点身份与编辑器配置。
  @override
  BlockComponentWidget buildWebBlock(BlockComponentContext context) =>
      _WebEmbedBlock(
        key: context.node.key,
        node: context.node,
        configuration: configuration,
      );
}

/// 借用网页嵌入节点，内容组件持有自身的网络或平台资源。
class _WebEmbedBlock extends CollabResourceBlock {
  /// [key] 控制状态复用；[node] 与 [configuration] 借用编辑器数据及配置。
  const _WebEmbedBlock({
    super.key,
    required super.node,
    required super.configuration,
  });

  /// 创建网页嵌入状态；不在构造阶段启动请求。
  @override
  State<_WebEmbedBlock> createState() => _WebEmbedBlockState();
}

/// 网页嵌入类型的独立状态，复用原选区、菜单及布局算法。
class _WebEmbedBlockState extends CollabEmbeddedWebBlockState<_WebEmbedBlock> {
  /// 使用既有本地类型名称，不写回共享属性。
  @override
  String get resourceLabel => '网页嵌入';

  /// 保留网页嵌入原有标题栏图标。
  @override
  IconData get webIcon => Icons.language;
}
