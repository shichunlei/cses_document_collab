import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart' show csesEmbedUrlAttribute;
import 'package:cses_document_collab/src/editor/collab_resource_block_base.dart';
import 'package:cses_document_collab/src/editor/collab_unsupported_block.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';

/// 附件块独立入口，保留文件图标、名称、大小和原有只读打开能力。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_attachment_block.dart';
/// final builder = CollabAttachmentBlockComponentBuilder();
/// // 在 AppFlowyEditor.blockComponentBuilders['attachment'] 注册。
/// ```
class CollabAttachmentBlockComponentBuilder extends BlockComponentBuilder {
  /// 创建不拥有编辑器或下载资源的附件构建器。
  CollabAttachmentBlockComponentBuilder();

  /// 附件必须为无正文、无子块的attachment引用。
  @override
  BlockComponentValidate get validate =>
      (node) => node.type == 'attachment' && node.delta == null && node.children.isEmpty;

  /// 使用借用[context]展示附件；无效地址沿用未知块保护，不发下载请求。
  @override
  BlockComponentWidget build(BlockComponentContext context) {
    final url = context.node.attributes[csesEmbedUrlAttribute] as String? ?? '';
    if (context.node.type != 'attachment' || !isCollabResourceUrl('attachment', url)) {
      return CollabUnsupportedBlockComponentBuilder().build(context);
    }
    return _AttachmentBlock(key: context.node.key, node: context.node, configuration: configuration);
  }
}

/// 借用附件引用与公共选区契约，不持有文件句柄或下载任务。
class _AttachmentBlock extends CollabResourceBlock {
  /// [key]控制身份复用，[node]及[configuration]由编辑器持有。
  const _AttachmentBlock({super.key, required super.node, required super.configuration});

  /// 创建附件展示与菜单状态。
  @override
  createState() => _AttachmentBlockState();
}

/// 附件展示不请求业务数据，操作沿用公共资源事务。
class _AttachmentBlockState extends CollabResourceBlockState<_AttachmentBlock> {
  /// 附件菜单与设置的展示名称。
  @override
  String get resourceLabel => '附件';

  /// 在借用[context]中维持原附件卡片样式，文件名为空时从已校验URL中回退。
  @override
  Widget buildResourceCard(BuildContext context) {
    final props = resource;
    final title = props.string('name').trim();
    final name = title.isNotEmpty
        ? title
        : Uri.parse(url).pathSegments.where((part) => part.trim().isNotEmpty).lastOrNull ?? '未命名附件';
    return Container(
      key: bodyKey,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
        child: Row(
          children: [
            Expanded(
              child: _AttachmentInfo(name: name, props: props),
            ),
            buildResourceMore(openLabel: '下载或打开附件'),
          ],
        ),
      ),
    );
  }
}

/// Displays a file badge, readable name and metadata; borrows immutable props.
/// Display fallbacks never write back into the document or fetch remote icons.
class _AttachmentInfo extends StatelessWidget {
  /// [name] is the display filename, with URL fallback already resolved.
  /// [props] supplies optional MIME type and size in bytes; neither is mutated.
  const _AttachmentInfo({required this.name, required this.props});

  /// Required display filename; long names occupy at most two lines.
  final String name;

  /// Borrowed file metadata; missing/invalid sizes display an explicit fallback.
  final CollabResource props;

  /// Builds the file identity in borrowed [context]; the parent owns the more menu.
  /// Narrow layouts use a smaller badge; metadata wraps under large text scaling.
  @override
  Widget build(BuildContext context) {
    final (icon, color, type) = _attachmentType(name, props.string('type'));
    final size = _attachmentSize(props.number('size'));
    return LayoutBuilder(
      builder: (context, constraints) {
        final badgeSize = constraints.maxWidth < 220 ? constraints.maxWidth.clamp(0.0, 40.0) : 48.0;
        final badge = ExcludeSemantics(
          child: Container(
            key: const ValueKey('attachment-file-icon'),
            width: badgeSize,
            height: badgeSize,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 26, color: color),
          ),
        );
        final details = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              key: const ValueKey('attachment-file-name'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, height: 1.4, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
            ),
            const SizedBox(height: 5),
            Text(
              '$type · $size',
              key: const ValueKey('attachment-file-metadata'),
              style: const TextStyle(fontSize: 12, height: 1.4, color: Color(0xFF64748B)),
            ),
          ],
        );
        if (constraints.maxWidth < 120) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [badge, const SizedBox(height: 8), details],
          );
        }
        return Row(
          children: [
            badge,
            const SizedBox(width: 12),
            Expanded(child: details),
          ],
        );
      },
    );
  }
}

/// Resolves a local file badge from [name]'s extension, then [mime] as fallback.
/// Unknown formats use a generic file icon and bounded extension label.
(IconData, Color, String) _attachmentType(String name, String mime) {
  final dot = name.lastIndexOf('.');
  final extension = dot > 0 && dot < name.length - 1 ? name.substring(dot + 1).toLowerCase() : '';
  final normalizedMime = mime.split(';').first.trim().toLowerCase();
  final kind = switch (extension) {
    'pdf' => 'pdf',
    'doc' || 'docx' || 'odt' || 'rtf' => 'document',
    'xls' || 'xlsx' || 'csv' || 'ods' => 'spreadsheet',
    'ppt' || 'pptx' || 'odp' => 'presentation',
    'zip' || 'rar' || '7z' || 'tar' || 'gz' => 'archive',
    'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'svg' || 'heic' => 'image',
    'mp3' || 'wav' || 'm4a' || 'aac' || 'ogg' || 'flac' => 'audio',
    'mp4' || 'mov' || 'mkv' || 'avi' || 'webm' => 'video',
    'txt' || 'md' || 'json' || 'xml' || 'log' => 'text',
    _ => switch (normalizedMime) {
      'application/pdf' => 'pdf',
      'application/msword' || 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' => 'document',
      'application/vnd.ms-excel' ||
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' => 'spreadsheet',
      'application/vnd.ms-powerpoint' ||
      'application/vnd.openxmlformats-officedocument.presentationml.presentation' => 'presentation',
      'application/zip' ||
      'application/x-zip-compressed' ||
      'application/x-rar-compressed' ||
      'application/x-7z-compressed' => 'archive',
      _ when normalizedMime.startsWith('image/') => 'image',
      _ when normalizedMime.startsWith('audio/') => 'audio',
      _ when normalizedMime.startsWith('video/') => 'video',
      _ when normalizedMime.startsWith('text/') => 'text',
      _ => 'file',
    },
  };
  final label = extension.isNotEmpty && extension.length <= 8
      ? extension.toUpperCase()
      : switch (kind) {
          'pdf' => 'PDF',
          'document' => '文档',
          'spreadsheet' => '表格',
          'presentation' => '演示文稿',
          'archive' => '压缩文件',
          'image' => '图片',
          'audio' => '音频',
          'video' => '视频',
          'text' => '文本',
          _ => '文件',
        };
  final (icon, color) = switch (kind) {
    'pdf' => (Icons.picture_as_pdf_outlined, const Color(0xFFDC5B54)),
    'document' => (Icons.description_outlined, const Color(0xFF3976D3)),
    'spreadsheet' => (Icons.table_chart_outlined, const Color(0xFF269468)),
    'presentation' => (Icons.slideshow_outlined, const Color(0xFFD78636)),
    'archive' => (Icons.folder_zip_outlined, const Color(0xFF8B65C4)),
    'image' => (Icons.image_outlined, const Color(0xFF4B88B5)),
    'audio' => (Icons.audio_file_outlined, const Color(0xFF8B65C4)),
    'video' => (Icons.video_file_outlined, const Color(0xFF3976D3)),
    'text' => (Icons.article_outlined, const Color(0xFF64748B)),
    _ => (Icons.insert_drive_file_outlined, const Color(0xFF64748B)),
  };
  return (icon, color, label);
}

/// Formats [bytes] in binary-scaled B/KB/MB/GB/TB units; null, negative and
/// non-finite values display unknown size. Zero is a known empty file.
String _attachmentSize(double? bytes) {
  if (bytes == null || !bytes.isFinite || bytes < 0) return '大小未知';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1)} ${units[unit]}';
}
