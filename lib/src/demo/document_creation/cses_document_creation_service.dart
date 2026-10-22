import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:cses_common/network/http/client/http_manager.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_document_collab/cses_document_collab.dart' show PreparedDocument;
import 'package:dio/dio.dart';
import 'document_creation_api.dart';
import 'document_creation_operation.dart';
import 'document_list_page.dart';

/// 绑定Common账号的新建HTTP适配器，不创建或释放HTTP客户端及主连接。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/document_creation/cses_document_creation_service.dart';
/// Future<void> inspectCreation() async {
///   final service = CsesDocumentCreationService(); // Common登录完成后创建。
///   final targets = await service.loadTargets();
///   if (targets.isNotEmpty) await service.verifyTarget(targets.first);
/// }
/// ```
final class CsesDocumentCreationService implements DocumentCreationApi {
  /// 捕获当前账号、企业、服务端和cookie；cookie只用于内存中的身份检查。
  CsesDocumentCreationService()
    : _userId = User().userId ?? '',
      _companyId = User().companyId,
      _server = ctx.websocketHost ?? '',
      _cookie = ctx.cookieId;
  final String _userId;
  final String _companyId;
  final String _server;

  /// 仅用于内存身份核对，不持久化、不进入scope，也不由本服务释放登录资源。
  final String? _cookie;

  /// 不包含凭证的稳定文件分区；cookie轮换不会改变账号恢复记录位置。
  String get scope =>
      sha256.convert(utf8.encode(jsonEncode([_server, _companyId, _userId]))).toString();

  /// 检查当前身份仍属于本次创建；失败时阻止后续HTTP与导航。
  @override
  void checkSession() {
    if (_userId.isEmpty ||
        _companyId.isEmpty ||
        _server.isEmpty ||
        _cookie == null ||
        _cookie.isEmpty ||
        User().userId != _userId ||
        User().companyId != _companyId ||
        ctx.websocketHost != _server ||
        ctx.cookieId != _cookie) {
      throw const FormatException('登录状态已变化，请重新打开创建页面');
    }
  }

  /// 使用Common已配置的Dio向[path]提交[params]，保留原始HTTP状态和传输异常；
  /// HttpManager.post会将两者折叠成业务失败，不能用于判断是否可安全重发。
  /// [checkAfter]仅建档响应设false，使协调器先归档原账号成功ID，再拒绝旧会话后续操作。
  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> params, {
    bool checkAfter = true,
  }) async {
    checkSession();
    Response<dynamic> response;
    try {
      HttpManager.getInstance();
      response = await HttpManager.dio!.post<dynamic>(path, data: params);
    } on DioException catch (error) {
      if (error.response?.statusCode == 401 || error.response?.statusCode == 403) {
        throw const DocumentCreationRejected('当前账号无权执行文档操作');
      }
      rethrow;
    }
    if (checkAfter) checkSession();
    if (response.data is! Map) throw const FormatException('文档接口响应格式错误');
    return Map<String, dynamic>.from(response.data as Map);
  }

  /// 验证[data]的明确业务结果；只有显式false视为拒绝，异常成功标志保持结果不明。
  void _requireSuccess(Map<String, dynamic> data) {
    if (data['isSuccess'] == false || (data['isSuccess'] == true && data['result'] == false)) {
      throw const DocumentCreationRejected('服务端未接受操作，请检查权限后重试');
    }
    if (data['isSuccess'] != true) throw const FormatException('文档接口缺少有效业务结果，请核对操作状态');
  }

  /// 读取空间；仅在个人空间缺失时初始化personal，不额外初始化企业空间。
  @override
  Future<List<DocumentCreationTarget>> loadTargets() async {
    Future<List<dynamic>> read() async {
      final data = await _post('/doc/space/list', {'pageNumber': 1, 'pageSize': 100});
      _requireSuccess(data);
      if (data['items'] is! List) throw const FormatException('空间列表格式错误');
      return data['items'] as List;
    }

    var items = await read();
    if (!items.any((item) => item is Map && item['spaceType'] == 'personal')) {
      _requireSuccess(await _post('/doc/space/init', {'type': 'personal'}));
      items = await read();
    }
    final valid = items
        .whereType<Map>()
        .where(
          (item) =>
              item['id'] is String && (item['id'] as String).isNotEmpty && item['name'] is String,
        )
        .toList();
    valid.sort(
      (a, b) =>
          (a['spaceType'] == 'personal' ? 0 : 1).compareTo(b['spaceType'] == 'personal' ? 0 : 1),
    );
    return valid
        .map(
          (item) => DocumentCreationTarget(id: item['id'] as String, name: item['name'] as String),
        )
        .toList(growable: false);
  }

  /// 分页读取[target]空间或文件夹的直接子文档；[pageNumber]从1开始，
  /// [pageSize]默认20且范围1～100。不传owner限制，使用服务端权限和createdAt倒序。
  /// 返回items/totalCount，忽略服务端可能缺省的hasMore；异常不生成空列表。
  Future<DocumentListPage> loadDocuments(
    DocumentCreationTarget target,
    int pageNumber, {
    int pageSize = 20,
  }) async {
    if (target.id.trim().isEmpty || pageNumber < 1 || pageSize < 1 || pageSize > 100) {
      throw const FormatException('文档列表查询参数无效');
    }
    final data = await _post('/doc/document/list', {
      'id': target.id,
      'pageNumber': pageNumber,
      'pageSize': pageSize,
      'timeSort': 'createdAt',
    });
    _requireSuccess(data);
    final items = data['items'];
    final total = data['totalCount'];
    if (items is! List || total is! int || total < 0) {
      throw const FormatException('文档列表分页数据格式错误');
    }
    return DocumentListPage(
      items: items
          .map((item) {
            if (item is! Map) throw const FormatException('文档列表条目格式错误');
            return DocumentListEntry.fromJson(Map<String, dynamic>.from(item));
          })
          .toList(growable: false),
      totalCount: total,
      pageNumber: pageNumber,
      pageSize: pageSize,
    );
  }

  /// 以createChild能力预检[target]；服务端仍在create时最终鉴权。
  @override
  Future<void> verifyTarget(DocumentCreationTarget target) async {
    if (target.id.trim().isEmpty) throw const FormatException('请选择新建位置');
    final data = await _post('/doc/permission/read', {'id': target.id});
    _requireSuccess(data);
    if (data['abilities'] is! Map || (data['abilities'] as Map)['createChild'] != true) {
      throw const DocumentCreationRejected('没有在所选位置新建文档的权限');
    }
  }

  /// 读取[documentId]详情，由服务端执行access鉴权并核对返回ID。
  /// 该读取可更新服务端访问行为；失败不改变本地文档或创建恢复记录。
  @override
  Future<void> verifyDocumentToOpen(String documentId) async {
    if (documentId.trim().isEmpty || documentId.length > 128) {
      throw const FormatException('请选择有效文档');
    }
    final data = await _post('/doc/document/view', {'id': documentId});
    _requireSuccess(data);
    if (data['id'] != documentId) throw const FormatException('文档不存在或已无权访问，请刷新列表');
  }

  /// 请求[target]下的正式空名文本ID；成功响应先返回ID供协调器持久化。
  @override
  Future<String> createBlank(DocumentCreationTarget target) async {
    final data = await _post('/doc/document/create', {
      'name': '',
      'documentType': 'text',
      'targetId': target.id,
    }, checkAfter: false);
    _requireSuccess(data);
    final id = data['result'];
    if (id is! String || id.trim().isEmpty || id.length > 128) {
      throw const FormatException('建档结果缺少有效ID，请在文档库核对');
    }
    return id;
  }

  /// 等待[prepared]对应初始块快照的业务返回；不宣称协同正文已落库。
  @override
  Future<void> writeInitial(PreparedDocument prepared) async {
    _requireSuccess(
      await _post('/doc/document/edit', {
        'docId': prepared.documentId,
        'blocks': prepared.insertDiffs,
      }),
    );
  }

  /// 读取[prepared]的完整根子树，严格核对初始字段；缺根不会自动重复Insert。
  @override
  Future<InitialSnapshotState> readInitial(PreparedDocument prepared) async {
    final data = await _post('/doc/document/block/read', {
      'docId': prepared.documentId,
      'blockId': prepared.documentId,
      'recursive': true,
    });
    _requireSuccess(data);
    if (data[prepared.documentId] == null) return InitialSnapshotState.missing;
    for (final expected in prepared.insertDiffs) {
      final actual = data[expected['id']];
      if (actual is! Map) return InitialSnapshotState.different;
      for (final key in [
        'id',
        'flavour',
        'nodeType',
        'props',
        'meta',
        'parentId',
        'children',
        'content',
        'text',
      ]) {
        if (expected.containsKey(key) && !_equal(actual[key], expected[key])) {
          return InitialSnapshotState.different;
        }
      }
    }
    return InitialSnapshotState.matches;
  }

  /// 比较[a]/[b]的JSON结构，Map顺序无关，数值遵循Dart等值规则。
  bool _equal(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every((key) => b.containsKey(key) && _equal(a[key], b[key]));
    }
    if (a is List && b is List) {
      return a.length == b.length &&
          List.generate(a.length, (i) => i).every((i) => _equal(a[i], b[i]));
    }
    return a == b;
  }

  /// 读取[documentId]的编辑授权；缺少editor角色或modify明确false时只读。
  /// 旧响应缺少modify能力字段时沿用服务端角色授权。
  Future<bool> editableFor(String documentId) async {
    final data = await _post('/doc/permission/read', {'id': documentId});
    _requireSuccess(data);
    final role = data['role'];
    final abilities = data['abilities'];
    return role is num && role >= 600 && (abilities is! Map || abilities['modify'] != false);
  }
}
