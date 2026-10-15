import 'package:cses_common/network/http/client/http_manager.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_document_collab/cses_document_collab.dart'
    show CollabMeetingCardData, CollabMeetingCardState;

/// 通过Common的同源会议详情接口提供卡片展示数据；不写协同文档，也不持有HTTP连接。
/// 实例绑定创建时的账号/企业/会话，切换后拒绝旧响应；宿主负责文档及认证生命周期。
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/cses_meeting_card_service.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// CollabHostServices servicesAfterLogin() => CollabHostServices(
///   loadMeetingCard: CsesMeetingCardService().load,
/// );
/// ```
final class CsesMeetingCardService {
  /// Common登录完成后捕获当前身份，不发请求；不创建或关闭共享客户端。
  CsesMeetingCardService()
    : _userId = User().userId,
      _companyId = User().companyId,
      _cookie = ctx.cookieId;

  /// 创建时账号，后续请求前后必须一致。
  final String? _userId;

  /// 创建时企业，用于隔离跨企业详情。
  final String _companyId;

  /// 创建时会话标识，仅用于本地失效检查，不进入卡片数据。
  final String? _cookie;

  /// 请求前后验证当前Common身份，缺少登录或会话变化抛FormatException。
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

  /// 读取稳定[meetingId]的本地展示快照，等待Common请求并复核账号/企业后返回。
  /// 接口明确返回空item/data时为null；未知meetingState保留unknown，非法身份/格式/业务拒绝抛FormatException。
  /// 网络错误透传，调用方负责展示重试；不会自行创建业务会议、入会或导航。
  Future<CollabMeetingCardData?> load(String meetingId) async {
    _checkSession();
    if (meetingId.trim().isEmpty) throw const FormatException('会议身份不可为空');
    final response = await HttpManager.getInstance().post(
      '/meeting/getDetail',
      params: {'meetingId': meetingId},
    );
    _checkSession();
    final responseData = response.data;
    if (responseData is! Map || responseData['isSuccess'] != true) {
      throw const FormatException('会议详情请求失败');
    }
    final Object? raw = responseData.containsKey('item')
        ? responseData['item']
        : responseData.containsKey('data')
        ? responseData['data']
        : responseData;
    if (raw == null) return null;
    if (raw is! Map || raw['meetingId'] != meetingId) {
      throw const FormatException('会议详情身份不匹配');
    }
    final state = _string(raw['meetingState']);
    final startTime = raw['startTime'];
    if (startTime != null &&
        (startTime is! int || startTime < 0 || startTime > 8640000000000000)) {
      throw const FormatException('会议开始时间格式错误');
    }
    final members = raw['members'];
    final count = raw['memberCount'];
    if (members != null && members is! List) {
      throw const FormatException('会议人员格式错误');
    }
    if (count != null && (count is! int || count < 0)) {
      throw const FormatException('会议人数格式错误');
    }
    return CollabMeetingCardData(
      meetingId: meetingId,
      state: CollabMeetingCardState.fromValue(state),
      title: _string(raw['title']),
      number: _string(raw['number']),
      startTime: startTime is int && startTime > 0
          ? DateTime.fromMillisecondsSinceEpoch(startTime, isUtc: true)
          : null,
      moderatorName: _string(raw['moderatorName']),
      memberCount: members is List ? members.length : count as int?,
    );
  }

  /// 将可选文本[value]校验为String或null，非法格式抛FormatException。
  String? _string(Object? value) {
    if (value == null || value is String) return value as String?;
    throw const FormatException('会议文本格式错误');
  }
}
