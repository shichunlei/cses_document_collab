import 'dart:convert';

import 'package:cses_document_collab/src/model/collab_resource.dart';

/// 桌面任务卡片的正式void类型，只保存引用身份和共享标题。
const collabTaskCardType = 'task';

/// 任务卡片属性载体；业务详情由宿主打开，不持有编辑器或网络资源。
/// ```dart
/// import 'package:cses_document_collab/src/model/collab_task_card.dart';
/// final resource = CollabTaskCard.read({'cses_resource': {'properties':
///   '{"taskId":"t1","title":"任务"}'}});
/// ```
abstract final class CollabTaskCard {
  /// 读取借用[attributes]的正式引用属性；不生成业务字段写入意图。
  static CollabResource read(Map<String, dynamic> attributes) {
    final raw = attributes[collabResourceAttribute];
    return raw is Map
        ? CollabResource.fromJson(Map<String, dynamic>.from(raw))
        : const CollabResource();
  }

  /// 校验[values]的稳定ID和标题；沿用提及的512字节ID与20000 UTF-16标题上限。
  static bool valid(Map<String, dynamic> values) =>
      values['taskId'] is String &&
      (values['taskId'] as String).trim().isNotEmpty &&
      utf8.encode(values['taskId'] as String).length <= 512 &&
      (values['title'] == null ||
          values['title'] is String &&
              (values['title'] as String).length <= 20000);
}
