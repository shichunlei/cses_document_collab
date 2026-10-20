import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart'
    show csesEmbedUrlAttribute;
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:cses_document_collab/src/ui/modal/collab_card_frame.dart';
import 'package:cses_document_collab/src/ui/modal/collab_card_header.dart';
import 'package:cses_document_collab/src/ui/modal/collab_embedded_page.dart';
import 'collab_link_actions.dart';
import 'collab_resource_block_base.dart';
import 'collab_unsupported_block.dart';

/// 网页构建器共用的结构及地址校验，不创建网络资源。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_bookmark_block.dart';
/// final builders = {'bookmark': CollabBookmarkBlockComponentBuilder()};
/// // 具体构建器继承公共校验，注册到 AppFlowyEditor。
/// ```
abstract class CollabWebBlockComponentBuilderBase
    extends BlockComponentBuilder {
  /// 创建无自有资源的校验基类，由具体网页类型提供视图。
  CollabWebBlockComponentBuilderBase();

  /// 当前独立构建器对应的共享节点类型。
  String get blockType;

  /// 校验当前类型无正文、无子块的既有结构。
  @override
  BlockComponentValidate get validate =>
      (node) =>
          node.type == blockType && node.delta == null && node.children.isEmpty;

  /// 使用借用的 [context] 构建内容；类型或地址无效时保留原节点并展示占位。
  @override
  BlockComponentWidget build(BlockComponentContext context) {
    final node = context.node;
    final url = node.attributes[csesEmbedUrlAttribute] as String? ?? '';
    if (node.type != blockType || !isCollabResourceUrl(node.type, url)) {
      return CollabUnsupportedBlockComponentBuilder().build(context);
    }
    return buildWebBlock(context);
  }

  /// 为已校验的借用 [context] 创建具体网页块，不转移编辑器资源所有权。
  BlockComponentWidget buildWebBlock(BlockComponentContext context);
}

/// 共用网页标题栏、链接菜单和布局算法，选区及事务仍由资源基类管理。
///
/// [T] 是具体网页 Widget，编辑器借用、异步请求和平台视图所有权保持各自原契约。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_figma_embed_block.dart';
/// final builders = {'figma-embed': CollabFigmaEmbedBlockComponentBuilder()};
/// // 具体块的状态复用此标题栏和尺寸算法，无需调用方释放额外资源。
/// ```
abstract class CollabWebBlockState<T extends CollabResourceBlock>
    extends CollabResourceBlockState<T> {
  /// 标题栏使用的既有类型图标，不下载站点图标。
  IconData get webIcon;

  /// 在借用的 [context] 下使用当前构建快照 [props] 创建网页预览或平台视图内容。
  Widget buildWebContent(BuildContext context, CollabResource props);

  /// 在借用的 [context] 下呈现双行标题与原有链接菜单，只读时隐藏更多。
  @override
  Widget buildResourceCard(BuildContext context) {
    final node = widget.node;
    final props = resource;
    final name = props.string('name').isNotEmpty
        ? props.string('name')
        : resourceLabel;
    final more = ExcludeFocus(
      child: IconButton(
        key: ValueKey('resource-more-$blockId'),
        tooltip: '更多操作',
        icon: const Icon(LucideIcons.ellipsis, size: 18),
        onPressed: () => showCollabLinkActions(
          context,
          node,
          onEdit: editResource,
          onDelete: deleteResource,
        ),
      ),
    );
    return CollabCardFrame(
      surfaceKey: bodyKey,
      margin: const EdgeInsets.symmetric(vertical: 6),
      header: CollabCardHeader(
        leading: Icon(webIcon),
        title: Text(
          props.string('title').trim().isNotEmpty
              ? props.string('title').trim()
              : name,
        ),
        subtitle: url,
        tinted: false,
        readOnly: !editor.editable,
        more: more,
      ),
      child: buildWebContent(context, props),
    );
  }

  /// 按原算法在 [context] 的约束内使用当前构建快照 [props] 布局，不写回共享尺寸。
  ///
  /// [bookmark] 为 true 时保留网页卡片占满可用宽度的规则；否则读取嵌入宽度。
  /// [contentBuilder] 接收当前构建上下文及限制到 180～720 逻辑像素的嵌入高度，
  /// 由调用方创建原内容组件并持有其资源；网页卡片忽略高度。
  Widget buildWebLayout(
    BuildContext context,
    CollabResource props, {
    required bool bookmark,
    required Widget Function(BuildContext context, double frameHeight)
    contentBuilder,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = bookmark ? null : props.number('wr');
        final cardWidth = width != null && width > 0
            ? constraints.maxWidth * (width.clamp(1, 100) / 100)
            : ((bookmark ? null : props.number('width')) ??
                      constraints.maxWidth)
                  .clamp(1.0, constraints.maxWidth);
        final ratio = props.number('ar');
        final frameHeight =
            (ratio != null && ratio > 0
                    ? cardWidth / ratio
                    : props.number('height') ?? cardWidth / (16 / 9))
                .clamp(180.0, 720.0);
        return Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: cardWidth,
            child: contentBuilder(context, frameHeight),
          ),
        );
      },
    );
  }
}

/// 共用 WebView 内容的状态基类，平台视图及换链处理仍归 CollabEmbeddedPage。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_web_embed_block.dart';
/// final builders = {'embed': CollabWebEmbedBlockComponentBuilder()};
/// // 注册具体类型即可复用嵌入布局，调用方不直接管理 WebView。
/// ```
abstract class CollabEmbeddedWebBlockState<T extends CollabResourceBlock>
    extends CollabWebBlockState<T> {
  /// 在借用 [context] 中按当前构建快照 [props] 构建原嵌入内容，保留组合键及高度约束。
  @override
  Widget buildWebContent(BuildContext context, CollabResource props) =>
      buildWebLayout(
        context,
        props,
        bookmark: false,
        contentBuilder: (context, frameHeight) => SizedBox(
          height: frameHeight,
          child: CollabEmbeddedPage(
            key: ValueKey('${widget.node.type}:$url'),
            url: url,
          ),
        ),
      );
}
