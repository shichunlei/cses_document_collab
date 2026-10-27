import 'package:cses_common/network/http/client/http_manager.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_document_collab/cses_document_collab.dart';

/// 将桌面同源KR响应映射为协同包公开契约；不拥有HTTP客户端。
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/service/cses_kr_service.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final services = CollabHostServices(kr: CsesKrService());
/// ```
final class CsesKrService implements CollabKrService {
  /// 在登录后捕获账号、企业及会话；变化时拒绝旧结果。
  CsesKrService() : _user = User().userId, _company = User().companyId, _cookie = ctx.cookieId;

  /// 创建时的账号、企业和会话；只作失效检查，不进入业务结果。
  final String? _user;

  /// 创建时企业，隔离跨企业查询。
  final String _company;

  /// 创建时会话，只用于失效检查，不输出到日志。
  final String? _cookie;

  /// 确认当前认证仍属于创建者，缺少认证或变化时抛FormatException。
  void _check() {
    if (_user == null ||
        _user.isEmpty ||
        _company.isEmpty ||
        _cookie == null ||
        User().userId != _user ||
        User().companyId != _company ||
        ctx.cookieId != _cookie) {
      throw const FormatException('登录状态已变化，请重新打开文档');
    }
  }

  /// 请求[path]及[params]，等待完成后核对身份；无效业务响应抛FormatException，网络异常透传。
  Future<List<dynamic>> _query(String path, Map<String, dynamic> params) async {
    _check();
    final response = await HttpManager.getInstance().post(path, params: params);
    _check();
    final raw = response.data;
    if (raw is! Map || raw['isSuccess'] != true) throw const FormatException('KR 请求失败');
    final items = raw['items'] ?? raw['list'] ?? raw['records'] ?? raw['data'];
    if (items is! List) throw const FormatException('KR 列表格式错误');
    return items;
  }

  /// 加载[meetingId]内已完成的主题及前三名，字段回退与桌面ACL一致；非法结构抛FormatException。
  @override
  Future<List<CollabKrTopic>> loadTopics(String meetingId) async {
    final items = await _query('/meetingKr/queryMeetingKrTopicList', {
      'meetingId': meetingId,
      'krStatuses': ['Completed'],
    });
    return List.unmodifiable(
      items.map((raw) {
        if (raw is! Map) throw const FormatException('KR 主题格式错误');
        final runs = raw['topKrRuns'] ?? const [];
        if (runs is! List) throw const FormatException('KR 条目格式错误');
        final krs = _items(runs, 0);
        final id = _string(raw['id'] ?? raw['krTopicId']);
        if (id.isEmpty) throw const FormatException('KR 主题身份为空');
        return CollabKrTopic(
          id: id,
          title: _string(raw['title'] ?? raw['topicTitle'] ?? raw['krTitle'], fallback: '主题'),
          total: _count(raw['totalCount'] ?? raw['total'] ?? raw['krCount'] ?? raw['count']) ?? krs.length,
          items: krs,
        );
      }),
    );
  }

  /// 续拉[meetingId]下[topicId]已加载[offset]条后的十条结果；请求与认证仍由宿主持有。
  @override
  Future<List<CollabKrItem>> loadMore(String meetingId, String topicId, int offset) async => _items(
    await _query('/krRun/queryVotedResultPageList', {'krTopicId': topicId, 'offset': offset, 'pageSize': 10}),
    offset,
  );

  /// 映射借用[raw]，以[offset]续接主题内序号；返回不可修改列表，非法结构抛FormatException。
  List<CollabKrItem> _items(List<dynamic> raw, int offset) =>
      List.unmodifiable([for (var i = 0; i < raw.length; i++) _item(raw[i], offset + i + 1)]);

  /// 映射单条[raw]及从1开始的[rank]，兼容桌面作者、正文和票数字段。
  CollabKrItem _item(dynamic raw, int rank) {
    if (raw is! Map) throw const FormatException('KR 格式错误');
    final author = raw['author'] ?? raw['creator'] ?? raw['user'] ?? const {};
    if (author is! Map) throw const FormatException('KR 作者格式错误');
    final id = _string(raw['id'] ?? raw['krRunId']);
    if (id.isEmpty) throw const FormatException('KR 身份为空');
    return CollabKrItem(
      id: id,
      rank: rank,
      title: _string(raw['krContent'] ?? raw['content'] ?? raw['title']),
      authorId: _string(raw['authorId'] ?? raw['creatorId'] ?? raw['userId'] ?? author['id'] ?? author['userId']),
      authorName: _string(
        raw['authorName'] ?? raw['creatorName'] ?? raw['userName'] ?? author['name'] ?? author['userName'],
      ),
      votes: _count(raw['voteCount'] ?? raw['votes'] ?? raw['voteNum']),
    );
  }

  /// 将[value]规范化为文本，null使用[fallback]；只接受字符串和有限数字。
  String _string(Object? value, {String fallback = ''}) {
    if (value == null) return fallback;
    if (value is String) return value.trim();
    if (value is num && value.isFinite) return value.toString();
    throw const FormatException('KR 文本格式错误');
  }

  /// 将[value]校验为可选非负计数，非法数值抛FormatException。
  int? _count(Object? value) {
    if (value == null) return null;
    if (value is num && value.isFinite && value >= 0 && value == value.roundToDouble()) return value.toInt();
    throw const FormatException('KR 计数格式错误');
  }
}
