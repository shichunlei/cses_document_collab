import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Renders meeting-only blocks while leaving their protocol data in the node.
///
/// Text blocks use AppFlowy's normal components. The host receives edit and
/// delete actions for media, dividers, embeds, and callouts.
class MeetingBlockBuilder extends BlockComponentBuilder {
  /// Creates a renderer for a meeting-only block type.
  MeetingBlockBuilder({required this.onEdit, required this.onDelete});

  /// Opens the protocol-property editor for a block owned by the host page.
  final ValueChanged<Node> onEdit;

  /// Requests removal of a block through the host editor transaction.
  final ValueChanged<Node> onDelete;

  @override
  BlockComponentWidget build(BlockComponentContext context) =>
      _MeetingBlockWidget(
        key: context.node.key,
        node: context.node,
        configuration: configuration,
        onEdit: onEdit,
        onDelete: onDelete,
      );
}

/// Displays a media card, rich divider, or nested callout for [node].
class _MeetingBlockWidget extends BlockComponentStatelessWidget {
  /// Creates the meeting block widget owned by the editor renderer.
  const _MeetingBlockWidget({
    super.key,
    required super.node,
    required super.configuration,
    required this.onEdit,
    required this.onDelete,
  });

  /// Opens the property form for this block.
  final ValueChanged<Node> onEdit;

  /// Removes this block from the editor document.
  final ValueChanged<Node> onDelete;

  /// Builds the meeting block and its edit controls using [context].
  @override
  Widget build(BuildContext context) {
    final source = node.attributes['_csesMeetingSource'];
    final data = source is Map ? source : const <String, dynamic>{};
    final propsValue = data['props'];
    final props = propsValue is Map ? propsValue : const <String, dynamic>{};

    if (node.type == 'divider') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [_buildActions(), _buildDivider(context, props)],
      );
    }
    if (node.type == 'cses_callout') {
      final editor = Provider.of<EditorState>(context, listen: false);
      final background = _color(props['backColor'], const Color(0xFFFFE6CD));
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _color(props['borderColor'], Colors.transparent),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${props['prefix'] ?? '💡'}',
                  style: const TextStyle(fontSize: 20),
                ),
                const Spacer(),
                _buildActions(),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: editor.renderer.buildList(context, node.children),
            ),
          ],
        ),
      );
    }

    final url = (props['url'] ?? props['src'])?.toString();
    if (node.type == 'image') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _buildActions(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                url ?? '',
                height: 220,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => _mediaCard(
                  context,
                  Icons.image_outlined,
                  '图片',
                  url,
                  withActions: false,
                ),
              ),
            ),
          ),
        ],
      );
    }

    final (icon, label) = switch (node.type) {
      'cses_audio' => (Icons.audiotrack_outlined, '音频'),
      'cses_video' => (Icons.ondemand_video_outlined, '视频'),
      'cses_attachment' => (Icons.attach_file, '附件'),
      'cses_bookmark' => (Icons.bookmark_outline, '网页书签'),
      'cses_figma_embed' => (Icons.design_services_outlined, 'Figma 嵌入'),
      'cses_juejin_embed' => (Icons.article_outlined, '掘金嵌入'),
      _ => (Icons.widgets_outlined, node.type),
    };
    final title = (props['title'] ?? props['name'] ?? label).toString();
    return _mediaCard(context, icon, title, url, subtitle: label);
  }

  /// Builds a divider matching the meeting node's style, size, and label.
  Widget _buildDivider(BuildContext context, Map props) {
    final style = props['style']?.toString() ?? 'solid';
    final thickness = switch (props['size']) {
      'thin' => 1.0,
      'medium' => 2.0,
      'large' => 4.0,
      _ => 2.0,
    };
    final color = _color(props['color'], Theme.of(context).colorScheme.outline);
    final line = LayoutBuilder(
      builder: (_, constraints) {
        final dotted = style == 'dotted' || style == 'dashed';
        if (!dotted) {
          return Container(
            height: style == 'double' ? thickness * 2 + 2 : thickness,
            decoration: style == 'double'
                ? BoxDecoration(
                    border: Border(
                      top: BorderSide(color: color, width: thickness),
                      bottom: BorderSide(color: color, width: thickness),
                    ),
                  )
                : BoxDecoration(color: color),
          );
        }
        final dash = style == 'dotted' ? 2.0 : 9.0;
        return Wrap(
          spacing: style == 'dotted' ? 4 : 5,
          children: List.generate(
            (constraints.maxWidth / (dash + 5)).floor().clamp(1, 200),
            (_) => Container(width: dash, height: thickness, color: color),
          ),
        );
      },
    );
    final text = props['text']?.toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: text == null || text.isEmpty
          ? line
          : Row(
              children: [
                if (props['align'] != 'left') Expanded(child: line),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(text, style: TextStyle(color: color)),
                ),
                if (props['align'] != 'right') Expanded(child: line),
              ],
            ),
    );
  }

  /// Builds a link card; opening it is an explicit user action.
  Widget _mediaCard(
    BuildContext context,
    IconData icon,
    String title,
    String? url, {
    String? subtitle,
    bool withActions = true,
  }) {
    return Card.outlined(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          subtitle == null ? url ?? '' : '$subtitle · ${url ?? ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: withActions ? _buildActions() : null,
        onTap: url == null ? null : () => _openLink(context, url),
      ),
    );
  }

  /// Provides explicit edit and delete actions for meeting-only blocks.
  Widget _buildActions() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: '编辑属性',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.edit_outlined, size: 20),
        onPressed: () => onEdit(node),
      ),
      IconButton(
        tooltip: '删除块',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.delete_outline, size: 20),
        onPressed: () => onDelete(node),
      ),
    ],
  );

  /// Opens [url] in the platform browser and reports an invalid link locally.
  Future<void> _openLink(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    final allowed =
        uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
    if (!allowed ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法打开此链接')));
      }
    }
  }

  /// Parses the sample's hexadecimal colors with a safe fallback.
  Color _color(Object? value, Color fallback) {
    if (value is! String || !value.startsWith('#')) return fallback;
    final hex = value.substring(1);
    if (hex.length != 6 && hex.length != 8) return fallback;
    final parsed = int.tryParse(hex, radix: 16);
    if (parsed == null) return fallback;
    return Color(hex.length == 6 ? 0xFF000000 | parsed : parsed);
  }
}
