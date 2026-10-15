import 'dart:async';

/// 正式提及的四类实体；名称与共享属性mentionType一致。
enum CollabMentionType {
  /// 企业用户，ID为人员身份。
  user,

  /// 会议引用，ID为会议身份。
  meeting,

  /// 任务引用，ID为任务身份。
  task,

  /// 文档引用，具体文档/附件类别保留在原始属性中。
  doc,
}

/// 一次提及点击的独立只读快照，不持有编辑器、路由或认证资源。
/// 嵌套Map/List均深复制并冻结，宿主可以在编辑器销毁后保留该值。
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final tap = CollabMentionTap(type: CollabMentionType.meeting,
///   id: 'm1', name: '周会', attributes: {
///     'mentionType': 'meeting', 'mentionId': 'm1', 'number': '123456',
///   });
/// final json = tap.toJson(); // type/id/name/attributes，可直接jsonEncode。
/// final services = CollabHostServices(onMentionTap: (mention) async {
///   print('${mention.type.name}: ${mention.id} ${mention.name}');
/// });
/// // 将services注入宿主持有的CollabController；资源仍由宿主释放。
/// ```
final class CollabMentionTap {
  /// [type] 为实体类型，[id] 为非空稳定身份，[name] 为共享正文原名，可为空。
  /// [attributes] 是原始Y.Text属性（含历史d:键和扩展），不含移动端私有投影键。
  /// 属性仅允许JSON值；空ID、非字符串Map键或非JSON值抛ArgumentError。
  /// 构造时深复制并冻结属性，不持有调用方可变集合。
  CollabMentionTap({
    required this.type,
    required this.id,
    required this.name,
    required Map<String, Object?> attributes,
  }) : attributes = _freezeAttribute(attributes) as Map<String, Object?> {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', '提及身份不可为空');
  }

  /// 必填实体类型，沿用user/meeting/task/doc四种共享语义。
  final CollabMentionType type;

  /// 必填稳定实体ID，不根据显示名推断。
  final String id;

  /// 必填共享名称，保留空名，不替换成界面的“未命名…”占位文案。
  final String name;

  /// 必填原始属性快照，嵌套集合只读；不是业务服务返回的实时详情或授权凭据。
  final Map<String, Object?> attributes;

  /// 返回可直接JSON编码的type/id/name/attributes对象，type使用user/meeting/task/doc字符串。
  /// 每次返回独立可变的顶层Map；attributes复用已深冻结的原始快照，保留空名、历史键及嵌套值。
  Map<String, Object?> toJson() => {
    'type': type.name,
    'id': id,
    'name': name,
    'attributes': attributes,
  };
}

/// 宿主接管提及点击；[mention] 为独立、深只读的原始快照。
/// 同步返回或等待Future均可；详情跳转应返回直到详情关闭的Future，期间暂停正文输入。
/// 配置后替代内置面板，预览也会调用；异常由编辑器报告并提示，不再补开内置面板。
/// 业务跳转、路由生命周期、权限及跨账号异步失效由宿主处理；编辑器不释放宿主资源。
typedef CollabMentionTapCallback =
    FutureOr<void> Function(CollabMentionTap mention);

/// 深复制JSON属性 [value]；[ancestors] 用于递归检测环，调用方省略以创建独立遍历。
/// 嵌套集合冻结，循环集合、非法键、非有限数及其他对象抛ArgumentError。
Object? _freezeAttribute(Object? value, {Set<Object>? ancestors}) {
  if (value == null || value is String || value is bool) return value;
  if (value is num && value.isFinite) return value;
  if (value is! List && value is! Map) {
    throw ArgumentError.value(value, 'attributes', '提及属性必须是JSON值');
  }
  final active = ancestors ?? Set<Object>.identity();
  if (!active.add(value)) throw ArgumentError('提及属性不可包含循环集合');
  try {
    if (value is List) {
      return List<Object?>.unmodifiable(
        value.map((child) => _freezeAttribute(child, ancestors: active)),
      );
    }
    return Map<String, Object?>.unmodifiable(
      (value as Map).map((key, child) {
        if (key is! String) throw ArgumentError('提及属性Map键必须是字符串');
        return MapEntry(key, _freezeAttribute(child, ancestors: active));
      }),
    );
  } finally {
    active.remove(value);
  }
}
