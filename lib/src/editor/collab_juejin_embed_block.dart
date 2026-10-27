import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'collab_resource_block_base.dart';
import 'collab_web_block_base.dart';

/// 掘金的独立节点构建器，复用网页校验和卡片外壳。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_juejin_embed_block.dart';
/// final builders = {'juejin-embed': CollabJuejinEmbedBlockComponentBuilder()};
/// // 将 builders 合并到 AppFlowyEditor.blockComponentBuilders。
/// ```
class CollabJuejinEmbedBlockComponentBuilder extends CollabWebBlockComponentBuilderBase {
  /// 创建不持有连接或平台视图的掘金构建器。
  CollabJuejinEmbedBlockComponentBuilder();

  /// 当前构建器只注册到 `juejin-embed` 节点。
  @override
  String get blockType => 'juejin-embed';

  /// 使用借用的 [context] 创建掘金，保持节点身份与编辑器配置。
  @override
  BlockComponentWidget buildWebBlock(BlockComponentContext context) =>
      _JuejinEmbedBlock(key: context.node.key, node: context.node, configuration: configuration);
}

/// 借用掘金节点，内容组件持有自身的网络或平台资源。
class _JuejinEmbedBlock extends CollabResourceBlock {
  /// [key] 控制状态复用；[node] 与 [configuration] 借用编辑器数据及配置。
  const _JuejinEmbedBlock({super.key, required super.node, required super.configuration});

  /// 创建掘金状态；不在构造阶段启动请求。
  @override
  createState() => _JuejinEmbedBlockState();
}

/// 掘金类型的独立状态，复用原选区、菜单及布局算法。
class _JuejinEmbedBlockState extends CollabEmbeddedWebBlockState<_JuejinEmbedBlock> {
  /// 使用既有本地类型名称，不写回共享属性。
  @override
  String get resourceLabel => '掘金';

  /// 使用Lucide报刊标识文章内容，不引入掘金品牌Logo。
  @override
  IconData get webIcon => LucideIcons.newspaper;
}
