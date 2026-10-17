import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'collab_link_preview.dart';
import 'collab_resource_block_base.dart';
import 'collab_web_block_base.dart';

/// 网页卡片的独立节点构建器，复用网页校验和卡片外壳。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_bookmark_block.dart';
/// final builders = {'bookmark': CollabBookmarkBlockComponentBuilder()};
/// // 将 builders 合并到 AppFlowyEditor.blockComponentBuilders。
/// ```
class CollabBookmarkBlockComponentBuilder extends CollabWebBlockComponentBuilderBase {
  /// [loadPreview] 借用元数据加载器，null 使用默认提取；请求仍由预览组件管理。
  CollabBookmarkBlockComponentBuilder({this.loadPreview});

  /// 可选借用加载器，不写共享属性，不转移所有权。
  final CollabLinkPreviewLoader? loadPreview;

  /// 当前构建器只注册到 `bookmark` 节点。
  @override
  String get blockType => 'bookmark';

  /// 使用借用的 [context] 创建网页卡片，保持节点身份与编辑器配置。
  @override
  BlockComponentWidget buildWebBlock(BlockComponentContext context) =>
      _BookmarkBlock(key: context.node.key, node: context.node, configuration: configuration, loadPreview: loadPreview);
}

/// 借用网页卡片节点，内容组件持有自身的网络或平台资源。
class _BookmarkBlock extends CollabResourceBlock {
  /// [key] 控制状态复用；[node] 与 [configuration] 借用编辑器数据及配置。
  /// [loadPreview] 是调用方可选加载器，null 沿用默认，不转移所有权。
  const _BookmarkBlock({super.key, required super.node, required super.configuration, this.loadPreview});

  /// 可选借用的元数据加载器，生命周期仍由预览组件管理。
  final CollabLinkPreviewLoader? loadPreview;

  /// 创建网页卡片状态；不在构造阶段启动请求。
  @override
  createState() => _BookmarkBlockState();
}

/// 网页卡片类型的独立状态，复用原选区、菜单及布局算法。
class _BookmarkBlockState extends CollabWebBlockState<_BookmarkBlock> {
  /// 使用既有本地类型名称，不写回共享属性。
  @override
  String get resourceLabel => '网页卡片';

  /// 使用Lucide书签标识网页卡片，保持原标题栏布局。
  @override
  IconData get webIcon => LucideIcons.bookmark;

  /// 在借用 [context] 下以当前构建快照 [props] 创建原卡片，保留换链键、加载器和打开行为。
  @override
  Widget buildWebContent(BuildContext context, CollabResource props) => buildWebLayout(
    context,
    props,
    bookmark: true,
    contentBuilder: (context, frameHeight) => CollabLinkPreview(
      key: ValueKey('${widget.node.type}:$url'),
      url: url,
      props: props,
      loadPreview: widget.loadPreview,
      onOpen: () => openResource(context),
    ),
  );
}
