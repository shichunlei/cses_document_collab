/// 正式文档业务头部快照；不参与正文块树、Yjs 或正文撤销历史。
/// 图标/封面复制为顶层只读 Map，嵌套值由宿主保留；不拥有网络或编辑器资源。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final detail = DocumentMetadata(id: 'doc', name: '任务', canRename: true);
/// final next = detail.apply(const DocumentMetadataPatch.rename('新标题'));
/// ```
class DocumentMetadata {
  /// [id] 为正式文档 ID，[name] 为业务名称；[icon]、[banner] 保留桌面字段。
  /// [icon]、[banner] 为 null 时表示未设置；仅复制顶层 Map，不校验业务资源。
  /// [canRename]、[canChangeAppearance] 默认 false，由宿主按权限和身份计算。
  DocumentMetadata({
    required this.id,
    required this.name,
    Map<String, dynamic>? icon,
    Map<String, dynamic>? banner,
    this.canRename = false,
    this.canChangeAppearance = false,
  }) : icon = icon == null ? null : Map.unmodifiable(icon),
       banner = banner == null ? null : Map.unmodifiable(banner);

  /// 正式文档 ID；实例不跨文档复用。
  final String id;

  /// 服务端业务名称；展示层为空时使用占位标题。
  final String name;

  /// 桌面图标原始字段；null 表示没有图标，未知类型仍保留。
  final Map<String, dynamic>? icon;

  /// 桌面封面原始字段；null 表示没有封面，y 为百分比位置。
  final Map<String, dynamic>? banner;

  /// 宿主计算的业务改名权限；编辑器只读和提交中状态由控制器进一步限制。
  final bool canRename;

  /// 宿主计算的封面/图标修改权限；不代表正文编辑权限。
  final bool canChangeAppearance;

  /// 只合并 [patch] 中显式出现的字段；null 图标/封面表示已移除。
  DocumentMetadata apply(DocumentMetadataPatch patch) => DocumentMetadata(
    id: id,
    name: patch.name ?? name,
    icon: patch.changesIcon ? patch.icon : icon,
    banner: patch.changesBanner ? patch.banner : banner,
    canRename: canRename,
    canChangeAppearance: canChangeAppearance,
  );
}

/// 单字段业务命令，区分“不修改”与“移除”；不持有网络或编辑器资源。
/// 由控制器校验权限和标题，服务只提交显式字段，避免覆盖其他业务元数据。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// const rename = DocumentMetadataPatch.rename('新标题');
/// const removeIcon = DocumentMetadataPatch.icon(null);
/// ```
class DocumentMetadataPatch {
  /// 构造业务改名命令；[value] 是待保存名称，控制器要求非空且不超过100个UTF-16码元。
  const DocumentMetadataPatch.rename(String value)
    : name = value,
      icon = null,
      banner = null,
      changesIcon = false,
      changesBanner = false;

  /// 构造图标命令；[icon] 为桌面 type/value Map，null 显式移除图标。
  const DocumentMetadataPatch.icon(this.icon)
    : name = null,
      banner = null,
      changesIcon = true,
      changesBanner = false;

  /// 构造封面命令；[banner] 含原图URL及位置，null 显式移除封面。
  const DocumentMetadataPatch.banner(this.banner)
    : name = null,
      icon = null,
      changesIcon = false,
      changesBanner = true;

  /// 非null表示改名；null表示不改变名称。
  final String? name;

  /// 图标负载；仅 [changesIcon] 为true时提交，null表示移除。
  final Map<String, dynamic>? icon;

  /// 封面负载；仅 [changesBanner] 为true时提交，null表示移除。
  final Map<String, dynamic>? banner;

  /// 是否显式修改图标，用于区分null移除和未修改。
  final bool changesIcon;

  /// 是否显式修改封面，用于区分null移除和未修改。
  final bool changesBanner;
}

/// 宿主借出的业务接口；鉴权、HTTP 封装和账号生命周期由宿主负责。
/// 编辑包只等待权威读写结果，不持有 cookie 或 Common 全局上下文；服务的释放由宿主负责。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// Future<void> renameOwnedDocument(DocumentMetadataService service, String id) async {
///   final detail = await service.load(id);
///   if (detail.canRename) {
///     await service.update(id, const DocumentMetadataPatch.rename('新标题'));
///   }
/// }
/// ```
abstract interface class DocumentMetadataService {
  /// 读取 [documentId] 的头部及当前权限；失败抛异常，不能伪造空头部。
  Future<DocumentMetadata> load(String documentId);

  /// 对 [documentId] 提交 [patch]；仅服务端确认成功时完成，失败抛异常。
  Future<void> update(String documentId, DocumentMetadataPatch patch);
}
