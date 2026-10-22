/// 新建操作的持久化阶段；sending阶段重启后先回读，不能盲目重复写入。
enum DocumentCreationStage {
  /// 已记录创建意图，即将或已经发送建档请求。
  creating,

  /// 建档请求结果不明，缺少正式ID，需人工核对。
  createUnknown,

  /// 已获得正式ID，等待本地正文准备。
  shellCreated,

  /// 正文及原生标记已落盘，尚未发送快照。
  bodyPrepared,

  /// 快照请求已发送，成功与否可能尚未确认。
  snapshotSending,

  /// 初始快照已被业务接口接受或回读核实。
  snapshotAccepted,

  /// 正式控制器已打开，后续编辑由协同层持有。
  completed,

  /// 服务端明确拒绝建档，可以开始新的操作。
  rejected,

  /// 用户已在文档库核对并明确结束未知结果；不代表服务端没有创建文档。
  reviewed,
}

/// 宿主选择的真实空间或文件夹，不持有授权或网络资源。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_operation.dart';
/// const target = DocumentCreationTarget(id: 'space-id', name: '个人空间');
/// ```
final class DocumentCreationTarget {
  /// [id] 是服务端目标ID，[name] 是仅用于展示的原始名称。
  const DocumentCreationTarget({required this.id, required this.name});

  /// 空间或文件夹的稳定ID。
  final String id;

  /// 创建页面展示名称，不能作为身份依据。
  final String name;
}

/// 不含凭证的创建恢复记录；每个账号分区保留最近一项操作。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_operation.dart';
/// final operation = DocumentCreationOperation(operationId: 'op', paragraphId: 'p',
///   createdAt: 1792584000000, target: const DocumentCreationTarget(id: 'space', name: '个人空间'));
/// final stored = operation.toJson();
/// ```
final class DocumentCreationOperation {
  /// [operationId]与[paragraphId]在发送前固定；[createdAt]为正整数epoch毫秒。
  /// [target]是创建位置，[stage]默认为请求已记录；[documentId]和[snapshotJson]
  /// 在获得相应结果后补齐。记录由宿主持久化，不包含cookie。
  const DocumentCreationOperation({
    required this.operationId,
    required this.paragraphId,
    required this.createdAt,
    required this.target,
    this.stage = DocumentCreationStage.creating,
    this.documentId,
    this.snapshotJson,
  });

  /// 当前创建操作的稳定ID，用于恢复与防重复。
  final String operationId;

  /// 初始空段落的稳定ID。
  final String paragraphId;

  /// 初始根元数据时间，单位毫秒，恢复时保持原值。
  final int createdAt;

  /// 建档位置，由本操作固定。
  final DocumentCreationTarget target;

  /// 最近持久化完成的操作阶段。
  final DocumentCreationStage stage;

  /// 已确认的服务端根ID；null表示尚未确认创建结果。
  final String? documentId;

  /// 同源原生初始快照；null表示尚未完成本地准备。
  final String? snapshotJson;

  /// 用[next]推进阶段；[documentId]及[snapshotJson]为null时保留原字段。
  DocumentCreationOperation advance(
    DocumentCreationStage next, {
    String? documentId,
    String? snapshotJson,
  }) => DocumentCreationOperation(
    operationId: operationId,
    paragraphId: paragraphId,
    createdAt: createdAt,
    target: target,
    stage: next,
    documentId: documentId ?? this.documentId,
    snapshotJson: snapshotJson ?? this.snapshotJson,
  );

  /// 返回独立JSON对象，供宿主账号分区保存。
  Map<String, dynamic> toJson() => {
    'version': 1,
    'operationId': operationId,
    'paragraphId': paragraphId,
    'createdAt': createdAt,
    'targetId': target.id,
    'targetName': target.name,
    'stage': stage.name,
    'documentId': documentId,
    'snapshotJson': snapshotJson,
  };

  /// 从[value]恢复版本1记录；字段缺失或阶段不合法抛FormatException。
  factory DocumentCreationOperation.fromJson(Map<String, dynamic> value) {
    final stage = DocumentCreationStage.values.where((s) => s.name == value['stage']).firstOrNull;
    if (value['version'] != 1 ||
        stage == null ||
        value['createdAt'] is! int ||
        (value['createdAt'] as int) <= 0 ||
        [
          'operationId',
          'paragraphId',
          'targetId',
          'targetName',
        ].any((key) => value[key] is! String) ||
        [
          'operationId',
          'paragraphId',
          'targetId',
        ].any((key) => (value[key] as String).trim().isEmpty) ||
        (value['documentId'] != null &&
            (value['documentId'] is! String || (value['documentId'] as String).trim().isEmpty)) ||
        (value['snapshotJson'] != null && value['snapshotJson'] is! String)) {
      throw const FormatException('创建恢复记录损坏，请核对服务端文档后处理');
    }
    if ([
          DocumentCreationStage.shellCreated,
          DocumentCreationStage.bodyPrepared,
          DocumentCreationStage.snapshotSending,
          DocumentCreationStage.snapshotAccepted,
          DocumentCreationStage.completed,
        ].contains(stage) &&
        value['documentId'] == null) {
      throw const FormatException('创建恢复记录缺少正式文档ID');
    }
    return DocumentCreationOperation(
      operationId: value['operationId'] as String,
      paragraphId: value['paragraphId'] as String,
      createdAt: value['createdAt'] as int,
      target: DocumentCreationTarget(
        id: value['targetId'] as String,
        name: value['targetName'] as String,
      ),
      stage: stage,
      documentId: value['documentId'] as String?,
      snapshotJson: value['snapshotJson'] as String?,
    );
  }
}

/// 服务端明确拒绝的操作；与传输中断造成的未知结果分开处理。
final class DocumentCreationRejected implements Exception {
  /// [message]为可展示的固定业务错误，不携带请求或凭证。
  const DocumentCreationRejected(this.message);

  /// 可展示的失败原因。
  final String message;

  /// 返回固定错误消息，避免意外展示请求上下文。
  @override
  String toString() => message;
}
