import 'dart:convert';

/// 一次新建操作的不可变初始快照；HTTP数据与已落盘的CRDT使用同一身份。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// void saveInitialSnapshot(PreparedDocument prepared) {
///   final body = {'docId': prepared.documentId, 'blocks': prepared.insertDiffs};
///   // 将body交给宿主已鉴权的HTTP服务，核验业务结果后打开正式文档。
///   print(body);
/// }
/// ```
final class PreparedDocument {
  /// 从原生或本地记录的[snapshotJson]恢复；仅接受root和一个空paragraph。
  /// 字段或结构不合法时抛FormatException，不修改存储或发起请求。
  PreparedDocument.fromSnapshotJson(String snapshotJson) : _snapshotJson = snapshotJson {
    final root = jsonDecode(snapshotJson);
    if (root is! Map<String, dynamic> ||
        root['id'] is! String ||
        (root['id'] as String).trim().isEmpty ||
        root['flavour'] != 'root' ||
        root['nodeType'] != 'root' ||
        root['props'] is! Map ||
        (root['props'] as Map).isNotEmpty ||
        !_validMeta(root['meta']) ||
        root.length != 6 ||
        root['children'] is! List ||
        (root['children'] as List).length != 1) {
      throw const FormatException('初始文档根不合法');
    }
    final paragraph = (root['children'] as List).single;
    if (paragraph is! Map<String, dynamic> ||
        paragraph['id'] is! String ||
        (paragraph['id'] as String).trim().isEmpty ||
        paragraph['id'] == root['id'] ||
        paragraph['flavour'] != 'paragraph' ||
        paragraph['nodeType'] != 'editable' ||
        paragraph['props'] is! Map ||
        (paragraph['props'] as Map).length != 1 ||
        paragraph['props']['depth'] != 0 ||
        paragraph['meta'] is! Map ||
        (paragraph['meta'] as Map).isNotEmpty ||
        paragraph.length != 6 ||
        paragraph['children'] is! List ||
        (paragraph['children'] as List).isNotEmpty) {
      throw const FormatException('初始文档段落不合法');
    }
    documentId = root['id'] as String;
    paragraphId = paragraph['id'] as String;
  }

  /// 唯一快照源；投影每次重新解码，不与调用方共享可变Map。
  final String _snapshotJson;

  /// 验证[value]为一次生成的根时间元数据，拒绝恢复文件夹带额外共享属性。
  static bool _validMeta(Object? value) {
    if (value is! Map || value.length != 2) return false;
    final time = value['createdTime'];
    final modified = value['lastModified'];
    return time is num &&
        time.isFinite &&
        time > 0 &&
        time % 1 == 0 &&
        modified is Map &&
        modified.length == 2 &&
        modified['time'] == time &&
        modified.containsKey('user') &&
        modified['user'] == null;
  }

  /// 服务端正式文档ID，也是正文根ID。
  late final String documentId;

  /// 本次初始化固定的空段落ID，恢复时不得重新生成。
  late final String paragraphId;

  /// 可持久化的初始化快照；仅含正文，不含账号凭证。
  String get snapshotJson => _snapshotJson;

  /// 每次返回独立的HTTP Insert投影；宿主变更返回值不改变原快照。
  /// 根children为稳定ID数组，段落content为空Delta，字段与桌面契约一致。
  List<Map<String, dynamic>> get insertDiffs {
    final root = jsonDecode(_snapshotJson) as Map<String, dynamic>;
    final paragraph = (root['children'] as List).single as Map<String, dynamic>;
    final paragraphData = {...paragraph}..remove('children');
    return [
      {
        ...root,
        'children': [paragraphId],
        'parentId': null,
        'mode': 'Insert',
      },
      {...paragraphData, 'content': <dynamic>[], 'text': '', 'parentId': documentId, 'mode': 'Insert'},
    ];
  }
}
