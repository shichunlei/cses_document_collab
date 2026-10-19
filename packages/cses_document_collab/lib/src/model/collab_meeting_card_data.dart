/// 宿主提供的会议业务状态，与服务端meetingState值一一对应；不写入协同正文。
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final state = CollabMeetingCardState.fromValue('Pause');
/// ```
enum CollabMeetingCardState {
  /// 会议尚未开始，使用蓝色。
  notStarted('NotStarted', '未开始'),

  /// 会议正在进行，使用绿色。
  inProgress('InProgress', '进行中'),

  /// 会议暂停，使用橙色。
  paused('Pause', '已暂停'),

  /// 会议已经结束，使用灰色并查看会议。
  completed('Completed', '已结束'),

  /// 会议已经取消，使用灰色并查看会议。
  canceled('Canceled', '已取消'),

  /// 业务会议已删除，禁用会议操作；仍允许移除文档引用。
  deleted('Delete', '已删除'),

  /// 未提供或无法识别状态，使用中性色，不推断会议已开始或结束。
  unknown('', '状态未知');

  /// [value] 是服务端状态字符串，[label] 是卡片中文状态文案。
  const CollabMeetingCardState(this.value, this.label);

  /// 服务端状态字符串；unknown使用空串。
  final String value;

  /// 展示文案，不作为服务端写入参数。
  final String label;

  /// 将服务端[value]解析为状态；null或未知字符串返回unknown。
  static CollabMeetingCardState fromValue(String? value) =>
      values.where((state) => state.value == value).firstOrNull ?? unknown;
}

/// 宿主加载的会议详情展示快照；只供本地卡片使用，不写回Y.Text或共享props。
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final services = CollabHostServices(loadMeetingCard: (meetingId) async =>
///   CollabMeetingCardData(meetingId: meetingId,
///     state: CollabMeetingCardState.paused, title: '周会', memberCount: 8));
/// ```
final class CollabMeetingCardData {
  /// [meetingId] 是非空稳定身份，必须与请求一致；[state] 默认unknown。
  /// [title]/[number] 为最新业务标题/编号，null沿用共享引用，空串保留为空。
  /// [startTime] 为可选开始时间，界面按设备本地时区展示；[moderatorName] 为可选主持人。
  /// [memberCount] 为可选非负参与人数；这些字段与底层业务资源均由宿主持有。
  const CollabMeetingCardData({
    required this.meetingId,
    this.state = CollabMeetingCardState.unknown,
    this.title,
    this.number,
    this.startTime,
    this.moderatorName,
    this.memberCount,
  }) : assert(meetingId != ''),
       assert(memberCount == null || memberCount >= 0);

  /// 必填稳定身份，不根据标题或编号推断。
  final String meetingId;

  /// 业务状态，默认unknown；结束/取消只影响按钮文案，不代替宿主鉴权。
  final CollabMeetingCardState state;

  /// 可选最新标题，null沿用文档中的共享标题。
  final String? title;

  /// 可选最新编号，null沿用文档中的共享编号。
  final String? number;

  /// 可选会议开始时间，按设备本地时区显示月日和时分。
  final DateTime? startTime;

  /// 可选主持人名称；null/空串不展示。
  final String? moderatorName;

  /// 可选非负参与人数；null不展示。
  final int? memberCount;
}

/// 宿主加载稳定[meetingId]的本地详情；null表示会议不存在，异常表示可重试加载失败。
/// 宿主持有认证及HTTP资源，包不关闭它们；加载结果不写正文，退出/换会话/换ID后迟到结果被忽略。
/// 仅在卡片挂载或ID/宿主变化、手动重试时加载；加入/查看按钮只派发回调，不触发加载，不包含实时推送订阅。
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final services = CollabHostServices(loadMeetingCard: (meetingId) async =>
///   CollabMeetingCardData(meetingId: meetingId, state: CollabMeetingCardState.completed));
/// ```
typedef CollabMeetingCardLoader = Future<CollabMeetingCardData?> Function(String meetingId);
