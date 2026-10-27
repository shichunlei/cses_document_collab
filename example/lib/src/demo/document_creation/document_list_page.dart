import 'document_creation_operation.dart';

/// 文档列表的一条只读元数据，不持有正文或协同资源。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_list_page.dart';
/// final item = DocumentListEntry.fromJson({'id': 'doc-id', 'name': ''});
/// print(item.displayName); // 无标题文档
/// ```
final class DocumentListEntry {
  /// 解析服务端[value]；ID必填，空标题按桌面语义展示为无标题文档。
  /// 时间字段为可选epoch毫秒；非法字段抛FormatException，不伪造列表记录。
  DocumentListEntry.fromJson(Map<String, dynamic> value)
    : id = _requiredId(value['id']),
      name = _name(value['name']),
      ownerName = value['owner'] is Map && value['owner']['name'] is String
          ? value['owner']['name'] as String
          : null,
      modifiedAt = _modifiedAt(value);

  /// 服务端文档ID，用于稳定行身份及分页去重。
  final String id;

  /// 原始名称，允许空字符串。
  final String name;

  /// 所有者名称；服务端未返回时为null，不自行读取人员信息。
  final String? ownerName;

  /// 创建、头部更新及正文编辑时间中的最新值；无时间数据时为null。
  final DateTime? modifiedAt;

  /// 可展示标题；空白名称使用统一的无标题提示。
  String get displayName => name.trim().isEmpty ? '无标题文档' : name;

  /// 验证[value]为非空服务端ID，拒绝不完整记录。
  static String _requiredId(Object? value) {
    if (value is! String || value.trim().isEmpty) throw const FormatException('文档列表缺少ID');
    return value;
  }

  /// 验证[value]为名称；null按未命名处理，其他非字符串值拒绝解析。
  static String _name(Object? value) {
    if (value == null) return '';
    if (value is! String) throw const FormatException('文档名称格式错误');
    return value;
  }

  /// 从[value]的可选毫秒时间取最新值，拒绝超出DateTime范围的数据。
  static DateTime? _modifiedAt(Map<String, dynamic> value) {
    int? latest;
    for (final key in ['createdAt', 'updatedAt', 'editedAt']) {
      final time = value[key];
      if (time == null) continue;
      if (time is! int || time < 0 || time > 8640000000000000) {
        throw const FormatException('文档时间格式错误');
      }
      if (latest == null || time > latest) latest = time;
    }
    return latest == null ? null : DateTime.fromMillisecondsSinceEpoch(latest);
  }
}

/// 服务端分页结果；页号来自请求，是否还有下一页依据totalCount计算。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_list_page.dart';
/// final page = DocumentListPage(items: [], totalCount: 0, pageNumber: 1, pageSize: 20);
/// print(page.hasMore); // false
/// ```
final class DocumentListPage {
  /// 借用[items]内容并复制为不可变列表；[totalCount]是服务端匹配总数。
  /// [pageNumber]从1开始，[pageSize]为1～100；参数非法时抛ArgumentError。
  DocumentListPage({
    required List<DocumentListEntry> items,
    required this.totalCount,
    required this.pageNumber,
    required this.pageSize,
  }) : items = List.unmodifiable(items) {
    if (totalCount < 0 || pageNumber < 1 || pageSize < 1 || pageSize > 100) {
      throw ArgumentError('文档分页参数无效');
    }
  }

  /// 当前页的不可变条目，保持服务端创建时间倒序。
  final List<DocumentListEntry> items;

  /// 服务端可见文档总数，不包含无权限或回收站记录。
  final int totalCount;

  /// 本次请求的页号，从1开始。
  final int pageNumber;

  /// 本次请求的每页数量。
  final int pageSize;

  /// 后端可能不提供hasMore，使用请求偏移与totalCount判断下一页。
  bool get hasMore => pageNumber * pageSize < totalCount;
}

/// 按[target]的真实父节点ID读取第[pageNumber]页，页码从1开始。
/// 请求及鉴权由宿主实现，展示组件只借用加载函数，不释放HTTP客户端。
typedef DocumentPageLoader =
    Future<DocumentListPage> Function(DocumentCreationTarget target, int pageNumber);
