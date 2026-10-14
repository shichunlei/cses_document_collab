// Generated from cses-client/packages/docs/src/document-content/metadata/
// components/doc-image-picker.catalog.ts. Do not edit the image list by hand.
// Update with tool/sync_document_cover_catalog.py and the desktop source path.

/// 桌面图库物料，不拥有网络资源；previewUrl用于缩略图，url用于业务保存。
///
/// ```dart
/// import 'package:cses_document_collab/src/model/document_cover_catalog.dart';
/// final image = documentCoverGroups.first.items.first;
/// final selectedUrl = image.url;
/// ```
class DocumentCoverImage {
  /// [id] 是稳定清单ID，[label] 是展示名称，[previewUrl] 为缩略图，[url] 为CSES原图。
  /// 参数来自桌面静态清单，本记录不校验网络可达性。
  const DocumentCoverImage(this.id, this.label, this.previewUrl, this.url);

  /// 稳定物料ID，用于点击键与清单核对。
  final String id;

  /// 展示名称，在缩略图加载失败时仍显示。
  final String label;

  /// 桌面缩略图URL，仅用于预览，不写入banner。
  final String previewUrl;

  /// CSES原图URL，选择后交给业务保存。
  final String url;
}

/// 桌面静态物料组，保留桌面顺序与名称；不拥有滚动或选择状态。
///
/// ```dart
/// import 'package:cses_document_collab/src/model/document_cover_catalog.dart';
/// final groups = documentCoverGroups;
/// final spaceImages = groups.first.items;
/// ```
class DocumentCoverGroup {
  /// [id] 是分组ID，[title] 为分组名称，[items] 为按桌面顺序排列的常量物料。
  const DocumentCoverGroup(this.id, this.title, this.items);

  /// 桌面稳定分组ID。
  final String id;

  /// 展示用分组名称。
  final String title;

  /// 分组内静态物料；生成清单为常量列表。
  final List<DocumentCoverImage> items;
}

/// 构建前从桌面源码同步的完整图库；更新由同步工具生成，运行时不查询图库接口。
const documentCoverGroups = <DocumentCoverGroup>[
  DocumentCoverGroup("space", "太空", [
    DocumentCoverImage(
      "space-telescope-1",
      "深空望远镜",
      "https://tc-cdn.flowus.cn/cover/spaceTelescope1?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e2163da564351b023cca7.png",
    ),
    DocumentCoverImage(
      "space-telescope-2",
      "星云",
      "https://tc-cdn.flowus.cn/cover/spaceTelescope2?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e217eda564351b023ccab.png",
    ),
    DocumentCoverImage(
      "space-telescope-4",
      "宇宙尘埃",
      "https://tc-cdn.flowus.cn/cover/spaceTelescope4?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e219004ec187e033c0eaa.png",
    ),
    DocumentCoverImage(
      "space-photo-1",
      "月面",
      "https://tc-cdn.flowus.cn/cover/photo1?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e21a004ec187e033c0ead.png",
    ),
    DocumentCoverImage(
      "space-photo-5",
      "蓝色星球",
      "https://tc-cdn.flowus.cn/cover/photo5?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e21b0da564351b023ccb7.png",
    ),
    DocumentCoverImage(
      "space-photo-11",
      "极光",
      "https://tc-cdn.flowus.cn/cover/photo11?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e21c004ec187e033c0eb5.png",
    ),
    DocumentCoverImage(
      "space-photo-9",
      "星际远航",
      "https://tc-cdn.flowus.cn/cover/photo9?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e21d104ec187e033c0eb8.png",
    ),
    DocumentCoverImage(
      "space-photo-12",
      "银河",
      "https://tc-cdn.flowus.cn/cover/photo12?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e21e004ec187e033c0ebb.png",
    ),
  ]),
  DocumentCoverGroup("painting", "油画", [
    DocumentCoverImage(
      "painting-1",
      "田野",
      "https://tc-cdn.flowus.cn/cover/img1?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e2204da564351b023ccc9.png",
    ),
    DocumentCoverImage(
      "painting-3",
      "花园",
      "https://tc-cdn.flowus.cn/cover/img3?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e2246da564351b023cccd.png",
    ),
    DocumentCoverImage(
      "painting-10",
      "湖光",
      "https://tc-cdn.flowus.cn/cover/img10?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e225604ec187e033c0ec8.png",
    ),
    DocumentCoverImage(
      "painting-19",
      "远山",
      "https://tc-cdn.flowus.cn/cover/img19?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e2284da564351b023ccdc.png",
    ),
    DocumentCoverImage(
      "painting-16",
      "花束",
      "https://tc-cdn.flowus.cn/cover/img16?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e229704ec187e033c0ecc.png",
    ),
    DocumentCoverImage(
      "painting-28",
      "日落",
      "https://tc-cdn.flowus.cn/cover/img28?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e22aa04ec187e033c0ecf.png",
    ),
    DocumentCoverImage(
      "painting-27",
      "海岸",
      "https://tc-cdn.flowus.cn/cover/img27?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e22bc04ec187e033c0ed2.png",
    ),
    DocumentCoverImage(
      "painting-33",
      "森林",
      "https://tc-cdn.flowus.cn/cover/img33?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e22cf04ec187e033c0ed7.png",
    ),
  ]),
  DocumentCoverGroup("creative", "创意", [
    DocumentCoverImage(
      "creative-4",
      "几何空间",
      "https://tc-cdn.flowus.cn/cover/flowus4?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e22e304ec187e033c0edc.png",
    ),
    DocumentCoverImage(
      "creative-5",
      "柔和彩带",
      "https://tc-cdn.flowus.cn/cover/flowus5?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e22f204ec187e033c0ee1.png",
    ),
    DocumentCoverImage(
      "creative-7",
      "纸张构成",
      "https://tc-cdn.flowus.cn/cover/flowus7?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e22ffda564351b023cd1d.png",
    ),
    DocumentCoverImage(
      "creative-8",
      "抽象光影",
      "https://tc-cdn.flowus.cn/cover/flowus8?img_process=/resize,w_640/quality,q_80/",
      "https://picture.jinqidongli.com/6552dcfe82f0120e04563fc6/695e230c04ec187e033c0ee5.png",
    ),
  ]),
];
