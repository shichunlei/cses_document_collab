import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart'
    show csesEmbedUrlAttribute;
import 'package:cses_document_collab/src/editor/collab_media_block_base.dart';
import 'package:flutter/material.dart';

/// 此文件仅保留原独立链接；图片与视频已迁到各自的独立构建器。
enum CollabEmbedKind {
  /// 旧独立链接卡片，保留原外观与打开行为。
  link,
}

/// 原独立链接的兼容构建器，不再分派图片或视频。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_embed_block.dart';
/// final builder = CollabEmbedBlockComponentBuilder(kind: CollabEmbedKind.link);
/// // 继续注册到原独立 link 类型，外观和业务保持不变。
/// ```
class CollabEmbedBlockComponentBuilder extends BlockComponentBuilder {
  /// [kind]保留旧链接调用入口；[configuration]为借用的原布局与选区配置。
  CollabEmbedBlockComponentBuilder({
    required this.kind,
    super.configuration = const BlockComponentConfiguration(),
  });

  /// 原独立链接类型，图片/视频通过各自构建器注册。
  final CollabEmbedKind kind;

  /// 保持旧链接的无正文、无子块和非空字符串地址校验。
  @override
  BlockComponentValidate get validate => (node) {
    final url = node.attributes[csesEmbedUrlAttribute];
    return node.children.isEmpty &&
        node.delta == null &&
        url is String &&
        url.isNotEmpty;
  };

  /// 使用借用[context]创建原链接视图，不改动模型或调用新的预览服务。
  @override
  BlockComponentWidget build(BlockComponentContext context) {
    final node = context.node;
    return _LinkBlock(
      key: node.key,
      node: node,
      configuration: configuration,
      showActions: showActions(node),
      actionBuilder: (anchor, state) => actionBuilder(context, state),
      actionTrailingBuilder: (anchor, state) =>
          actionTrailingBuilder(context, state),
    );
  }
}

/// 借用原链接节点、工具栏和布局配置，不持有媒体控制器。
class _LinkBlock extends CollabMediaBlock {
  /// [key]控制身份复用；[node]/[configuration]、[showActions]、[actionBuilder]及
  /// [actionTrailingBuilder]沿用编辑器借用的原配置。
  const _LinkBlock({
    super.key,
    required super.node,
    required super.configuration,
    super.showActions,
    super.actionBuilder,
    super.actionTrailingBuilder,
  });

  /// 创建仅展示旧独立链接的状态。
  @override
  State<_LinkBlock> createState() => _LinkBlockState();
}

/// 旧独立链接保留自己的内容，共用原媒体外壳和菜单布局。
class _LinkBlockState extends CollabMediaBlockState<_LinkBlock> {
  /// 在借用[context]中装配原链接内容。
  @override
  Widget buildMedia(BuildContext context) => _buildLinkCard(context);

  /// 保留借用[context]中的原更多入口，不增加新的只读操作。
  @override
  Widget? buildMediaActions(BuildContext context) => buildMediaMore(context);

  /// 在借用[context]中保留旧独立链接的图标、主机名、地址与点击外部打开行为。
  Widget _buildLinkCard(BuildContext context) {
    final uri = Uri.tryParse(url);
    final displayHost = uri?.host.isNotEmpty == true ? uri!.host : '外部链接';
    return Material(
      color: const Color(0xFFF5F7FB),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: const ValueKey('collab-link-block-open'),
        borderRadius: BorderRadius.circular(14),
        onTap: () => openExternally(context),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0xFFDBEAFE),
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: EdgeInsets.all(10),
                  child: Icon(Icons.link, color: Color(0xFF2563EB)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayHost,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      url,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.open_in_new, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
