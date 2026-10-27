import 'collab_user_mention.dart';

/// 任务优先级或状态标签；色值沿用桌面的十六进制色板，不持有界面状态。
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// const priority = CollabTaskCardTag(name: '一般', color: '#59B463');
/// ```
final class CollabTaskCardTag {
  /// [name]为业务标签原名，[color]为可选#RRGGBB色值；null使用中性灰。
  const CollabTaskCardTag({required this.name, this.color});

  /// 必填标签名称；空串时不显示标签。
  final String name;

  /// 可选桌面标签色；非法值按中性灰展示，不修改业务数据。
  final String? color;
}

/// 任务所在空间、项目或工作项的路径节点，只用于展示。
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// const path = CollabTaskCardPath(name: '企业空间', type: 'space');
/// ```
final class CollabTaskCardPath {
  /// [name]为原始节点名称，[type]为space/project/workItem或宿主其他类型，仅控制图标。
  const CollabTaskCardPath({required this.name, required this.type});

  /// 必填节点名称，不作为路由身份。
  final String name;

  /// 必填路径类型，未知类型显示文件夹图标。
  final String type;
}

/// 宿主提供的任务卡片本地快照，不写回共享taskId/title，也不持有业务资源。
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final services = CollabHostServices(loadTaskCard: (id) async =>
///   CollabTaskCardData(taskId: id, title: '测试状态111–111',
///     priority: const CollabTaskCardTag(name: '一般', color: '#59B463'),
///     status: const CollabTaskCardTag(name: '待开始'), progress: 0,
///     fileCount: 0, subTaskCount: 0));
/// ```
final class CollabTaskCardData {
  /// [taskId]为非空请求身份，[title]为可选业务标题，null沿用共享标题。
  /// [priority]/[status]为可选标签，[leaders]为负责人，最多展示前三位并汇总其余人数。
  /// [startTime]/[endTime]为可选起止时间，按设备本地时区显示月日和时分。
  /// [progress]为0～100的有限百分数，null表示未知；[fileCount]/[subTaskCount]为可选非负计数。
  /// [path]为按空间/项目/工作项排序的节点，[deleted]默认false，true禁用详情但仍可删除引用。
  /// 复制并冻结列表；非法身份、进度或计数抛ArgumentError，不保留调用方可变列表。
  CollabTaskCardData({
    required this.taskId,
    this.title,
    this.priority,
    this.status,
    List<CollabMentionUser> leaders = const [],
    this.startTime,
    this.endTime,
    this.progress,
    this.fileCount,
    this.subTaskCount,
    List<CollabTaskCardPath> path = const [],
    this.deleted = false,
  }) : leaders = List.unmodifiable(leaders),
       path = List.unmodifiable(path) {
    if (taskId.trim().isEmpty ||
        progress != null &&
            (!progress!.isFinite || progress! < 0 || progress! > 100) ||
        fileCount != null && fileCount! < 0 ||
        subTaskCount != null && subTaskCount! < 0) {
      throw ArgumentError('任务卡片身份、进度或计数无效');
    }
  }

  /// 必填稳定任务ID，必须与请求一致。
  final String taskId;

  /// 可选业务标题，空串仍表示空名称。
  final String? title;

  /// 可选优先级，未提供时不伪造“一般”。
  final CollabTaskCardTag? priority;

  /// 可选状态，只展示，不提供业务流转操作。
  final CollabTaskCardTag? status;

  /// 冻结的负责人列表，头像通过宿主mentionAvatarBuilder构建。
  final List<CollabMentionUser> leaders;

  /// 可选开始时间，按设备本地时区展示。
  final DateTime? startTime;

  /// 可选截止时间，按设备本地时区展示。
  final DateTime? endTime;

  /// 可选0～100进度；未知时只显示灰色轨道，不伪造0%。
  final double? progress;

  /// 可选非负附件数；null时隐藏统计。
  final int? fileCount;

  /// 可选非负子任务数；null时隐藏统计。
  final int? subTaskCount;

  /// 冻结的路径节点，空列表不显示路径。
  final List<CollabTaskCardPath> path;

  /// 任务已删除时禁用详情，不删除文档中的引用。
  final bool deleted;
}

/// 加载稳定[taskId]的本地展示快照；null明确表示不存在，异常表示可重试失败。
/// 宿主持有认证/网络，编辑包不关闭借用资源；关闭、换ID/宿主后忽略迟到结果。
/// 仅挂载、身份/宿主变化、手动重试时加载，打开详情只回调，不触发刷新；不包含实时订阅。
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final services = CollabHostServices(loadTaskCard: (id) async =>
///   CollabTaskCardData(taskId: id, title: '任务'));
/// ```
typedef CollabTaskCardLoader =
    Future<CollabTaskCardData?> Function(String taskId);
