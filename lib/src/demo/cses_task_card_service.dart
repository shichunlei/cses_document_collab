import 'package:cses_common/network/http/client/http_manager.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_document_collab/cses_document_collab.dart'
    show
        CollabTaskCardData,
        CollabTaskCardTag,
        CollabTaskCardPath,
        CollabMentionUser;

/// 通过Common读取任务卡片详情，绑定创建时账号/企业/会话，不拥有共享HTTP客户端。
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/cses_task_card_service.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// CollabHostServices servicesAfterLogin() => CollabHostServices(
///   loadTaskCard: CsesTaskCardService().load,
/// );
/// ```
final class CsesTaskCardService {
  /// 登录后冻结当前身份，不发请求，不创建或关闭共享客户端。
  CsesTaskCardService()
    : _userId = User().userId,
      _companyId = User().companyId,
      _cookie = ctx.cookieId;

  /// 创建时账号，只用于隔离请求。
  final String? _userId;

  /// 创建时企业，不写入卡片。
  final String _companyId;

  /// 创建时会话，仅在本地比较，不传给组件。
  final String? _cookie;

  /// 请求前后校验身份；缺登录或会话变更抛FormatException。
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

  /// 按桌面task_v3/detail契约读取[taskId]；null表示明确空item，异常表示请求或数据失败。
  /// 仅返回本地展示快照，进度归一为0～100；不打开详情、不修改任务或协同正文。
  /// 等待请求完成后复核当前账号/企业，网络错误透传，由编辑器显示重试。
  Future<CollabTaskCardData?> load(String taskId) async {
    _checkSession();
    if (taskId.trim().isEmpty) throw const FormatException('任务身份不可为空');
    final response = await HttpManager.getInstance().post(
      '/taskManage/task/detail',
      params: {'queryType': 'detail', 'tableName': 'task_v3', 'id': taskId},
    );
    _checkSession();
    final body = response.data;
    if (body is! Map ||
        body['isSuccess'] != true ||
        !body.containsKey('item')) {
      throw const FormatException('任务详情请求失败');
    }
    final raw = body['item'];
    if (raw == null) return null;
    if (raw is! Map || raw['id'] != taskId) {
      throw const FormatException('任务详情身份不匹配');
    }
    final leaders = raw['leaders'];
    if (leaders != null && leaders is! List) {
      throw const FormatException('任务负责人格式错误');
    }
    return CollabTaskCardData(
      taskId: taskId,
      title: _text(raw['title']),
      priority: _tag(raw['priority']),
      status: _tag(raw['status']),
      leaders: [
        if (leaders is List)
          for (final leader in leaders) _leader(leader),
      ],
      startTime: _time(raw['startTime']),
      endTime: _time(raw['endTime']),
      progress: raw['progress'] == null ? null : _progress(raw['progress']),
      fileCount: _count(raw['fileCount']),
      subTaskCount: _count(raw['subCount']),
      path: [
        for (final type in ['space', 'project', 'workItem'])
          if (raw[type] != null) _path(raw[type], type),
      ],
    );
  }

  /// 校验可选文本[value]，非法格式抛FormatException。
  String? _text(Object? value) {
    if (value == null || value is String) return value as String?;
    throw const FormatException('任务文本格式错误');
  }

  /// 将标签[value]转换为只读外观快照，空值隐藏，非法对象抛FormatException。
  CollabTaskCardTag? _tag(Object? value) {
    if (value == null) return null;
    if (value is! Map) throw const FormatException('任务标签格式错误');
    return CollabTaskCardTag(
      name: _text(value['name']) ?? '',
      color: _text(value['color']),
    );
  }

  /// 将负责人[value]的user快照转换为宿主头像参数，缺身份时抛FormatException。
  CollabMentionUser _leader(Object? value) {
    final user = value is Map ? value['user'] : null;
    if (user is! Map) throw const FormatException('任务负责人格式错误');
    final id = _text(user['userId']) ?? _text(user['id']);
    if (id == null || id.isEmpty) throw const FormatException('任务负责人身份缺失');
    return CollabMentionUser(
      id: id,
      name: _text(user['name']) ?? '',
      avatarUrl: _text(user['avatarUrl']),
    );
  }

  /// 将路径[value]作为[type]节点展示；非法对象或名称抛FormatException。
  CollabTaskCardPath _path(Object? value, String type) {
    if (value is! Map) throw const FormatException('任务路径格式错误');
    return CollabTaskCardPath(name: _text(value['nodeName']) ?? '', type: type);
  }

  /// 转换毫秒时间[value]；null或0表示未设置，越界或非整数抛FormatException。
  DateTime? _time(Object? value) {
    if (value == null || value == 0) return null;
    if (value is! int || value < 0 || value > 8640000000000000) {
      throw const FormatException('任务时间格式错误');
    }
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }

  /// 校验计数[value]；null保留未知，非整数/负数抛FormatException。
  int? _count(Object? value) {
    if (value == null || value is int && value >= 0) return value as int?;
    throw const FormatException('任务计数格式错误');
  }

  /// 兼容桌面的数值/数字字符串进度[value]，保留两位小数并限制0～100；非法值归0。
  double _progress(Object? value) {
    final number = value is num
        ? value.toDouble()
        : value is String
        ? double.tryParse(value)
        : null;
    if (number == null || !number.isFinite) return 0;
    return (number.clamp(0, 100) * 100).roundToDouble() / 100;
  }
}
