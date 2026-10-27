import 'package:cses_document_collab/src/model/document_cover_catalog.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 将桌面静态清单显示为分组图库；缩略图失败仍可选择CSES原图，不执行业务保存。
/// 父组件提供滚动区域，本视图只按宽度排三列/四列，不拥有业务控制器。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/document_cover_gallery.dart';
/// import 'package:flutter/material.dart';
/// Widget gallery() => SingleChildScrollView(
///   child: DocumentCoverGallery(selectedUrl: '', onSelected: (image) => debugPrint(image.url)),
/// );
/// ```
class DocumentCoverGallery extends StatelessWidget {
  /// [key] 标识视图；[selectedUrl] 是当前原图URL，空值表示无选中项。
  /// [onSelected] 必填，点击时同步交出原图记录，保存和权限由调用方处理。
  const DocumentCoverGallery({super.key, required this.selectedUrl, required this.onSelected});

  /// 当前原图URL，用于选中边框和语义，状态由调用方持有。
  final String selectedUrl;

  /// 借用的点击回调，收到清单原记录；缩略图错误不阻止回调。
  final ValueChanged<DocumentCoverImage> onSelected;

  /// 在 [context] 中按父宽度展示有限的20张清单；不持有滚动状态，网络图片失败显示占位。
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final group in documentCoverGroups) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(group.title, style: Theme.of(context).textTheme.titleSmall),
          ),
          GridView.count(
            primary: false,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: constraints.maxWidth >= 520 ? 4 : 3,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.53,
            children: [for (final image in group.items) _tile(image)],
          ),
          const SizedBox(height: 22),
        ],
      ],
    ),
  );

  /// 用清单 [image] 展示缩略图和名称，点击交出原图记录；选中样式不修改业务状态。
  Widget _tile(DocumentCoverImage image) => Semantics(
    button: true,
    selected: image.url == selectedUrl,
    label: image.label,
    child: Material(
      color: const Color(0xFFE9EBF1),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('document-cover-${image.id}'),
        onTap: () => onSelected(image),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.network(
              image.previewUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const Center(child: Icon(LucideIcons.image, color: Color(0xFF7C8799))),
            ),
            if (image.url == selectedUrl)
              const DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.fromBorderSide(BorderSide(color: Color(0xFF6558D9), width: 2)),
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                ),
              ),
            if (image.url == selectedUrl)
              Positioned(
                right: 4,
                bottom: 4,
                child: Container(
                  width: 19,
                  height: 19,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(color: Color(0xFF6558D9), shape: BoxShape.circle),
                  child: const Icon(LucideIcons.check, size: 13, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
