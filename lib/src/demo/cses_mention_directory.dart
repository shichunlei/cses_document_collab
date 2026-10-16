import 'package:cses_common/network/http/client/http_manager.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_document_collab/cses_document_collab.dart' show CollabMentionDirectory, CollabMentionUser;
import 'package:flutter/foundation.dart';

/// 使用桌面同源企业组织树提供人员搜索/资料；借用Common认证与HTTP。
/// 每实例绑定账号/企业/会话，缓存只活到文档宿主释放，不拥有连接。
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/cses_mention_directory.dart';
/// Future<void> queryAfterLogin() async {
///   final directory = CsesMentionDirectory();
///   final users = await directory.search('张');
///   if (users.isNotEmpty) await directory.load(users.first.id);
/// }
/// ```
final class CsesMentionDirectory implements CollabMentionDirectory {
  /// 登录后创建并捕获身份；不发请求，账号切换后旧实例拒绝查询。
  CsesMentionDirectory() : _userId = User().userId, _companyId = User().companyId, _cookie = ctx.cookieId;

  /// 创建时的登录用户，账号切换使实例失效。
  final String? _userId;

  /// 创建时的企业，用于请求隔离与缓存作用域。
  final String _companyId;

  /// 创建时的会话，仅用于身份检查，不进入人员或协同数据。
  final String? _cookie;

  /// 本实例共享的加载Future，失败清除以便重试；成功后缓存不可变人员列表。
  Future<List<CollabMentionUser>>? _users;

  /// 前后核对借用Common会话；身份变化抛FormatException，不缓存旧账号响应。
  void _checkSession() {
    if (_userId == null ||
        _userId.isEmpty ||
        _companyId.isEmpty ||
        _cookie == null ||
        User().userId != _userId ||
        User().companyId != _companyId ||
        ctx.cookieId != _cookie) {
      throw const FormatException('登录状态已变化，请重新打开文档');
    }
  }

  /// 加载当前企业完整人员树；解析在后台执行，失败向调用方抛出。
  Future<List<CollabMentionUser>> _fetch() async {
    _checkSession();
    final response = await HttpManager.getInstance().post(
      '/Company/readAllChildren',
      params: {'orgId': _companyId, 'isReadUser': true},
    );
    _checkSession();
    final data = response.data;
    if (data is! Map || data['isSuccess'] != true || data['items'] is! List) {
      throw const FormatException('人员列表格式错误');
    }
    final users = await compute(_flattenMentionUsers, data['items'] as List);
    _checkSession();
    return users;
  }

  /// 返回当前身份的共享加载结果，失败撤销缓存，允许下次重试。
  Future<List<CollabMentionUser>> _all() async {
    _checkSession();
    final pending = _users ??= _fetch();
    try {
      final result = await pending;
      _checkSession();
      return result;
    } catch (_) {
      if (identical(_users, pending)) _users = null;
      rethrow;
    }
  }

  /// 搜索 [keyword] 的姓名/部门/职位，空值返回全部人员；后台过滤后重新校验身份。
  @override
  Future<List<CollabMentionUser>> search(String keyword) async {
    final users = await _all();
    final result = await compute(_searchMentionUsers, (users, keyword));
    _checkSession();
    return result;
  }

  /// 读取 [userId] 的同源资料，不存在返回null；Future完成前校验账号。
  @override
  Future<CollabMentionUser?> load(String userId) async {
    final users = await _all();
    return users.where((u) => u.id == userId).firstOrNull;
  }
}

/// 将组织树 [roots] 在后台扁平化，只取真实用户且按ID去重；非法节点拒绝整个请求。
List<CollabMentionUser> _flattenMentionUsers(List roots) {
  final result = <String, CollabMentionUser>{};
  final pending = List<Object?>.from(roots);
  while (pending.isNotEmpty) {
    final item = pending.removeLast();
    if (item is! Map) throw const FormatException('人员节点格式错误');
    if (item['isUser'] == true) {
      final id = item['id'];
      final name = item['name'];
      if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
        throw const FormatException('人员身份格式错误');
      }
      result[id] = CollabMentionUser(
        id: id,
        name: name,
        department: item['deptName'] as String?,
        position: item['orgName'] as String?,
      );
    }
    final children = item['children'];
    if (children != null) {
      if (children is! List) throw const FormatException('人员子树格式错误');
      pending.addAll(children);
    }
  }
  return List.unmodifiable(result.values);
}

/// 对后台输入 [request] 的列表/关键词进行大小写无关过滤，不修改缓存。
List<CollabMentionUser> _searchMentionUsers((List<CollabMentionUser>, String) request) {
  final keyword = request.$2.trim().toLowerCase();
  return request.$1
      .where((u) => '${u.name} ${u.department ?? ''} ${u.position ?? ''}'.toLowerCase().contains(keyword))
      .toList();
}
