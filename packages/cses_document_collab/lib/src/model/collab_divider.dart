import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';

/// 正式桌面分割线 flavour，同时作为手机无正文节点的类型。
const collabDividerType = 'divider';

/// 可编辑属性与旧版尺寸；缺失和显式 null 保持区分以支持精确撤销。
const collabDividerKeys = {
  'style',
  'length',
  'thickness',
  'opacity',
  'lineColor',
  'size',
};

/// 桌面三类预设的持久化键和移动端标签，顺序与桌面面板一致。
const collabDividerStyles = {
  'solid': '实线',
  'dashed': '虚线',
  'dotted': '点线',
  'double': '双线',
  'fade': '渐隐',
  'wave': '波浪',
  'zigzag': '锯齿',
  'sketch': '手绘',
  'triple-dot': '三点',
  'diamond': '菱形',
  'tape-dot-black': '彩虹胶带',
  'tape-grid-pattern': '格纹胶带',
  'tape-regular-lines': '细纹胶带',
  'tape-gradient-blocks': '渐变胶带',
  'tape-gray-lines': '灰纹胶带',
  'edge-grass': '枝叶',
  'edge-flower': '花簇',
  'edge-vine': '藤蔓',
  'edge-daisy': '雏菊',
  'edge-stars': '星芒',
  'edge-berries': '浆果',
};

/// [property] 的 AppFlowy 历史字段；不与资源卡片的字段共用命名。
String dividerPropertyAttribute(String property) => 'cses_divider_$property';

/// 桌面分割线的只读展示解析；原始数据继续留在权威共享 props。
///
/// 借用现有 [CollabResource] 的属性补丁载体，不引入 URL 或正文语义。
/// 未识别样式以实线展示，读取回落不生成属性写入。
/// ```dart
/// import 'package:cses_document_collab/src/model/collab_divider.dart';
/// final divider = CollabDivider({'size': 'small'});
/// print(divider.length); // medium
/// ```
final class CollabDivider {
  /// 借用不可变的 [values]；缺失属性按当前桌面默认值展示。
  const CollabDivider(this.values);

  /// 原始已适配属性；调用方持有，不得在实例存活期间修改。
  final Map<String, dynamic> values;

  /// 支持的样式键，未知或空值展示实线且不覆盖原值。
  String get style => collabDividerStyles.containsKey(values['style'])
      ? values['style'] as String
      : 'solid';

  /// short/medium/long/full，优先显式 length，否则按旧 size 回落。
  String get length =>
      const {'short', 'medium', 'long', 'full'}.contains(values['length'])
      ? values['length'] as String
      : switch (values['size']) {
          'thin' => 'short',
          'small' => 'medium',
          'large' => 'full',
          null => 'full',
          _ => 'long',
        };

  /// thin/regular/thick，旧 thin/small 均为细；未设置默认细。
  String get thickness =>
      const {'thin', 'regular', 'thick'}.contains(values['thickness'])
      ? values['thickness'] as String
      : switch (values['size']) {
          'thin' || 'small' || null => 'thin',
          'large' => 'thick',
          _ => 'regular',
        };

  /// 桌面 Number 转换并钳制到 0.1～1；缺失或不可转换为 1，null 为 0.1。
  double get opacity {
    final raw = values['opacity'];
    final number = !values.containsKey('opacity')
        ? null
        : raw == null
        ? 0.0
        : raw is num
        ? raw.toDouble()
        : raw is bool
        ? (raw ? 1.0 : 0.0)
        : raw is String
        ? (raw.trim().isEmpty ? 0.0 : double.tryParse(raw))
        : null;
    return number != null && number.isFinite ? number.clamp(0.1, 1.0) : 1.0;
  }

  /// CSS 线色原值；空字符串表示跟随主题，胶带本身保留多色图案。
  String get lineColor =>
      values['lineColor'] is String ? values['lineColor'] as String : '';

  /// 中心对齐的长度比例，分别为 25%、50%、75% 和 100%。
  double get widthRatio => switch (length) {
    'short' => .25,
    'medium' => .5,
    'long' => .75,
    _ => 1,
  };

  /// 从 [attributes] 解码独立历史字段；[edited] 默认空，仅显式操作生成补丁。
  /// 返回桥接既有载体，撤销时空 wrapper 删除属性而带 value:null 保留显式 null。
  static CollabResource readAttributes(
    Map<String, dynamic> attributes, {
    Set<String> edited = const {},
  }) {
    final raw = attributes[collabResourceAttribute];
    final resource = raw is Map
        ? CollabResource.fromJson(Map<String, dynamic>.from(raw))
        : const CollabResource();
    final values = resource.values;
    final patch = <String, dynamic>{};
    for (final key in collabDividerKeys) {
      final field = attributes[dividerPropertyAttribute(key)];
      if (field is! String) {
        continue;
      }
      final wrapper = jsonDecode(field) as Map;
      if (wrapper.containsKey('value')) {
        values[key] = wrapper['value'];
      } else {
        values.remove(key);
      }
      if (edited.contains(key)) {
        patch[key] = wrapper;
      }
    }
    return CollabResource.fromValues(
      values,
      edits: patch.isEmpty ? null : jsonEncode(patch),
    );
  }

  /// 将 [resource] 的原始属性拆为可独立撤销的编辑器字段，不写权威数据。
  static Map<String, dynamic> nodeAttributes(CollabResource resource) => {
    collabResourceAttribute: resource.toJson(),
    for (final key in collabDividerKeys)
      dividerPropertyAttribute(key): resource.field(key),
  };
}

/// 在借用的 [state] 内按稳定 [id] 修改分割线的单一 [property]。
/// [value] 为新的桌面属性；null 清除该属性。只读、已删除或非法值返回 false。
/// 逐项封闭历史，撤销可跨远端重排重新定位，不释放编辑器资源；事务失败透传。
Future<bool> changeCollabDividerProperty(
  EditorState state,
  String id,
  String property,
  Object? value,
) async {
  if (state.isDisposed ||
      !state.editable ||
      !collabDividerKeys.contains(property)) {
    return false;
  }
  final valid =
      value == null ||
      switch (property) {
        'style' => collabDividerStyles.containsKey(value),
        'length' => const {'short', 'medium', 'long', 'full'}.contains(value),
        'thickness' => const {'thin', 'regular', 'thick'}.contains(value),
        'size' => const {'thin', 'small', 'medium', 'large'}.contains(value),
        'opacity' =>
          value is num && value.isFinite && value >= .1 && value <= 1,
        'lineColor' => value is String && value.length <= 256,
        _ => false,
      };
  if (!valid) {
    return false;
  }
  final node = findCollabDivider(state, id);
  if (node == null) {
    return false;
  }
  final key = dividerPropertyAttribute(property);
  final next = jsonEncode(value == null ? {} : {'value': value});
  if (node.attributes[key] == next) {
    return false;
  }
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  await state.apply(
    state.transaction..add(
      UpdateOperation(
        node.path,
        {
          key: next,
          collabResourceTargetAttribute: id,
          collabResourceKindAttribute: collabDividerType,
        },
        {
          key: node.attributes[key],
          collabResourceTargetAttribute: id,
          collabResourceKindAttribute: collabDividerType,
        },
      ),
    ),
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
  return true;
}

/// 在借用 [state] 的完整树中按稳定 [id] 找分割线，删除/销毁返回 null。
Node? findCollabDivider(EditorState state, String id) {
  if (state.isDisposed) {
    return null;
  }

  /// 递归读取借用 [node]，不修改属性或保存节点引用。
  Node? visit(Node node) {
    if ((node.attributes['cses_collab_block_id'] ?? node.id) == id &&
        node.type == collabDividerType) {
      return node;
    }
    for (final child in node.children) {
      final found = visit(child);
      if (found != null) {
        return found;
      }
    }
    return null;
  }

  return visit(state.document.root);
}

/// 在借用 [state] 的保存 [selection] 起点插入正式分割线并返回后置段落光标。
/// 空正文被替换，非空正文保留；新块使用独立身份，可插在根或高亮容器内。
/// 只读/已失效位置返回 null；不恢复输入焦点，调用方须等待添加面板退出。
Future<Selection?> insertCollabDivider(
  EditorState state,
  Selection selection,
) async {
  if (state.isDisposed || !state.editable || selection.start.path.isEmpty) {
    return null;
  }
  final source = state.getNodeAtPath(selection.start.path);
  if (source == null ||
      !const {'page', 'callout'}.contains(source.parent?.type)) {
    return null;
  }
  final divider = Node(
    type: collabDividerType,
    attributes: CollabDivider.nodeAttributes(const CollabResource()),
  );
  divider.updateAttributes({'cses_collab_block_id': divider.id});
  final empty = source.delta?.toPlainText().isEmpty == true;
  final path = empty ? source.path : source.path.next;
  final transaction = state.transaction
    ..insertNodes(path, [divider, paragraphNode()], deepCopy: false);
  if (empty) {
    transaction.deleteNode(source);
  }
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  await state.apply(transaction, skipHistoryDebounce: true);
  return Selection.single(path: path.next, startOffset: 0);
}
