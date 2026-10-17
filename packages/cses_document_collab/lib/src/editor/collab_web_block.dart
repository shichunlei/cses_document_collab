import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart' show csesEmbedUrlAttribute;
import 'package:cses_document_collab/src/editor/collab_card_frame.dart';
import 'package:cses_document_collab/src/editor/collab_embedded_page.dart';
import 'package:cses_document_collab/src/editor/collab_link_actions.dart';
import 'package:cses_document_collab/src/editor/collab_link_preview.dart';
import 'package:cses_document_collab/src/editor/collab_resource_block_base.dart';
import 'package:cses_document_collab/src/editor/collab_unsupported_block.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';

/// 网页资源独立构建器，覆盖网页卡片、网页嵌入、掘金与Figma。
/// 不解析账号或宿主上下文；元数据加载器仍由调用方持有。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_web_block.dart';
/// final builder = CollabWebBlockComponentBuilder();
/// // 为 bookmark/embed/juejin-embed/figma-embed 分别注册此构建器。
/// ```
class CollabWebBlockComponentBuilder extends BlockComponentBuilder {
  /// [loadPreview]可替换网页卡片元数据提取，null沿用默认；构建器不释放调用方加载器。
  CollabWebBlockComponentBuilder({this.loadPreview});

  /// 可选借用的元数据加载器，只有bookmark视图使用，不写共享属性。
  final CollabLinkPreviewLoader? loadPreview;

  /// 仅接受四类网页资源的无正文、无子块结构。
  @override
  BlockComponentValidate get validate =>
      (node) => _webTypes.contains(node.type) && node.delta == null && node.children.isEmpty;

  /// 用借用[context]创建网页卡片或嵌入；无效地址保持原数据并展示保护性占位。
  @override
  BlockComponentWidget build(BlockComponentContext context) {
    final node = context.node;
    final url = node.attributes[csesEmbedUrlAttribute] as String? ?? '';
    if (!_webTypes.contains(node.type) || !isCollabResourceUrl(node.type, url)) {
      return CollabUnsupportedBlockComponentBuilder().build(context);
    }
    return _WebBlock(key: node.key, node: node, configuration: configuration, loadPreview: loadPreview);
  }
}

/// 本文件独立负责的网页块类型，不包含音频或附件。
const _webTypes = {'bookmark', 'embed', 'figma-embed', 'juejin-embed'};

/// 借用网页节点与可选加载器，平台视图由内容组件持有。
class _WebBlock extends CollabResourceBlock {
  /// [key]控制身份复用；[node]/[configuration]借用编辑器，[loadPreview]借用调用方加载器。
  const _WebBlock({super.key, required super.node, required super.configuration, this.loadPreview});

  /// 可选的元数据加载器；null使用默认提取，不转移所有权。
  final CollabLinkPreviewLoader? loadPreview;

  /// 创建网页布局和操作状态，不在构造时启动网络请求。
  @override
  createState() => _WebBlockState();
}

/// 网页布局和链接菜单的独立实现；共同选区和事务由基类维护。
class _WebBlockState extends CollabResourceBlockState<_WebBlock> {
  /// 按当前网页类型显示本地名称，不写入共享属性。
  @override
  String get resourceLabel => switch (widget.node.type) {
    'bookmark' => '网页卡片',
    'figma-embed' => 'Figma',
    'juejin-embed' => '掘金',
    _ => '网页嵌入',
  };

  /// 当前类型的既有图标；不下载站点图标。
  IconData get _icon => switch (widget.node.type) {
    'bookmark' => Icons.bookmark_border,
    'figma-embed' => Icons.design_services_outlined,
    'juejin-embed' => Icons.article_outlined,
    _ => Icons.language,
  };

  /// 在借用[context]中显示双行标题栏与原有预览/WebView尺寸，保留当前内容组件身份。
  @override
  Widget buildResourceCard(BuildContext context) {
    final node = widget.node;
    final kind = node.type;
    final props = resource;
    final name = props.string('name').isNotEmpty ? props.string('name') : resourceLabel;
    final more = ExcludeFocus(
      child: IconButton(
        key: ValueKey('resource-more-$blockId'),
        tooltip: '更多操作',
        icon: const Icon(Icons.more_horiz, size: 18),
        onPressed: () => showCollabLinkActions(context, node, onEdit: editResource, onDelete: deleteResource),
      ),
    );
    return CollabCardFrame(
      surfaceKey: bodyKey,
      margin: const EdgeInsets.symmetric(vertical: 6),
      header: CollabCardHeader(
        leading: Icon(_icon),
        title: Text(props.string('title').trim().isNotEmpty ? props.string('title').trim() : name),
        subtitle: url,
        tinted: false,
        readOnly: !editor.editable,
        more: more,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = kind == 'bookmark' ? null : props.number('wr');
          final cardWidth = width != null && width > 0
              ? constraints.maxWidth * (width.clamp(1, 100) / 100)
              : ((kind == 'bookmark' ? null : props.number('width')) ?? constraints.maxWidth).clamp(
                  1.0,
                  constraints.maxWidth,
                );
          final ratio = props.number('ar');
          final frameHeight =
              (ratio != null && ratio > 0 ? cardWidth / ratio : props.number('height') ?? cardWidth / (16 / 9)).clamp(
                180.0,
                720.0,
              );
          return Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: cardWidth,
              child: kind != 'bookmark'
                  ? SizedBox(
                      height: frameHeight,
                      child: CollabEmbeddedPage(key: ValueKey('$kind:$url'), url: url),
                    )
                  : CollabLinkPreview(
                      key: ValueKey('$kind:$url'),
                      url: url,
                      props: props,
                      loadPreview: widget.loadPreview,
                      onOpen: () => openResource(context),
                    ),
            ),
          );
        },
      ),
    );
  }
}
