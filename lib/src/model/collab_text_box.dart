import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';

/// 文本框的正式容器类型，正文由独立子节点保存。
const collabTextBoxType = 'text-box';

/// 桌面独立外观组及几何字段；未知原始属性仍由共享文档保留。
const collabTextBoxKeys = {
  'width',
  'height',
  'rotation',
  'lockRatio',
  'shape',
  'fill',
  'fillOpacity',
  'outline',
  'lineEnds',
  'arrows',
  'shadow',
  'glow',
  'textPadding',
  'textAlignment',
  'textDirection',
  'textWrap',
  'textAutoFit',
  'textRotate',
  'textFamily',
  'textFont',
  'textSpacing',
  'textFill',
  'textFillOpacity',
  'textOutline',
  'textShadow',
  'textGlow',
  'textTransform',
  'textFit',
  'artwork',
  'adjustments',
  'position',
  'placementLayer',
};

/// 桌面允许的直接正文子节点；不允许媒体或嵌套容器。
const collabTextBoxChildren = {'paragraph', 'heading', 'bulleted_list', 'numbered_list', 'todo_list', 'quote'};

/// 返回[property]的独立本地字段键，包装值保留缺失与null差异。
String textBoxPropertyAttribute(String property) => 'cses_text_box_$property';

/// 将借用[resource]投影为字段，不生成默认值或取得其所有权。
Map<String, dynamic> textBoxNodeAttributes(CollabResource resource) => {
  collabResourceAttribute: resource.toJson(),
  for (final key in collabTextBoxKeys) textBoxPropertyAttribute(key): resource.field(key),
};

/// 读取借用[attributes]中的当前属性；[edited]仅标记显式修改字段。
CollabResource readCollabTextBox(Map<String, dynamic> attributes, {Set<String> edited = const {}}) {
  final raw = attributes[collabResourceAttribute];
  final values = raw is Map ? CollabResource.fromJson(Map<String, dynamic>.from(raw)).values : <String, dynamic>{};
  final edits = <String, dynamic>{};
  for (final key in collabTextBoxKeys) {
    final field = attributes[textBoxPropertyAttribute(key)];
    if (field is! String) continue;
    final wrapper = jsonDecode(field) as Map;
    if (wrapper.containsKey('value')) {
      values[key] = wrapper['value'];
    } else {
      values.remove(key);
    }
    if (edited.contains(key)) edits[key] = wrapper;
  }
  return CollabResource.fromValues(values, edits: edits.isEmpty ? null : jsonEncode(edits));
}

/// 创建调用方拥有的240×120矩形文本框，首个空段落继续使用普通输入链路。
Node createCollabTextBox() {
  final node = Node(
    type: collabTextBoxType,
    attributes: textBoxNodeAttributes(
      CollabResource.fromValues({'width': 240, 'height': 120, 'shape': 'rectangle', 'lockRatio': false}),
    ),
    children: [paragraphNode()],
  );
  node.updateAttributes({'cses_collab_block_id': node.id});
  return node;
}

/// 在借用[state]的折叠[selection]后插入文本框，空正文原位替换。
/// 仅根、高亮和单列父级可插入；锁定、只读或失效选区返回null，异常向上传播。
Future<Selection?> insertCollabTextBox(EditorState state, Selection selection) async {
  if (state.isDisposed || !state.editable || !selection.isCollapsed) return null;
  final source = state.getNodeAtPath(selection.start.path);
  if (source == null ||
      !const {'page', 'callout', 'column'}.contains(source.parent?.type) ||
      !canEditCollabNode(state, source)) {
    return null;
  }
  final node = createCollabTextBox();
  final replace = source.type == 'paragraph' && source.delta?.isEmpty == true;
  final path = replace ? source.path : source.path.next;
  final landing = Selection.single(path: path + [0], startOffset: 0);
  final tx = state.transaction;
  if (replace) tx.deleteNode(source);
  tx.insertNode(path, node, deepCopy: false);
  tx.afterSelection = landing;
  if (state.undoManager.undoStack.isNonEmpty) state.undoManager.undoStack.last.seal();
  await state.apply(tx, skipHistoryDebounce: true);
  return landing;
}

/// 对借用[state]中稳定[id]的文本框应用[patch]字段，null移除覆盖。
/// 字段独立撤销，未变化不写历史；不支持字段抛ArgumentError，锁/失效身份返回false。
Future<bool> updateCollabTextBox(EditorState state, String id, Map<String, dynamic> patch) async {
  final node = findCollabActionNode(state, id);
  if (node == null || node.type != collabTextBoxType || !canEditCollabNode(state, node)) return false;
  if (!patch.keys.every(collabTextBoxKeys.contains)) {
    throw ArgumentError('不支持的文本框属性');
  }
  for (final key in ['width', 'height']) {
    final value = patch[key];
    if (value != null && (value is! num || !value.isFinite || value < (key == 'width' ? 48 : 32) || value > 2000)) {
      throw ArgumentError('文本框尺寸无效');
    }
  }
  final before = readCollabTextBox(node.attributes).values;
  final changed = <String, dynamic>{
    for (final e in patch.entries)
      if (e.value == null ? before.containsKey(e.key) : jsonEncode(before[e.key]) != jsonEncode(e.value))
        e.key: e.value,
  };
  if (changed.isEmpty) return false;
  final identity = {collabResourceTargetAttribute: id, collabResourceKindAttribute: collabTextBoxType};
  final tx = state.transaction
    ..add(
      UpdateOperation(
        node.path,
        {
          ...identity,
          for (final e in changed.entries)
            textBoxPropertyAttribute(e.key): jsonEncode(e.value == null ? {} : {'value': e.value}),
        },
        {
          ...identity,
          for (final key in changed.keys)
            textBoxPropertyAttribute(key): node.attributes[textBoxPropertyAttribute(key)] ?? '{}',
        },
      ),
    );
  if (state.undoManager.undoStack.isNonEmpty) state.undoManager.undoStack.last.seal();
  await state.apply(tx, withUpdateSelection: false, skipHistoryDebounce: true);
  return true;
}

/// 删除借用[state]中稳定[id]的整个文本框；拒绝未知后代或任何后代锁。
/// 末项补空段落，独立历史保留子树身份；关闭、只读或失效对象返回false。
Future<bool> deleteCollabTextBox(EditorState state, String id) async {
  final node = findCollabActionNode(state, id);
  if (node == null ||
      node.type != collabTextBoxType ||
      !canEditCollabNode(state, node) ||
      (CollabBlockLocks.of(state)?.state(id).containsLock ?? false) ||
      node.children.any(
        (c) => !collabTextBoxChildren.contains(c.type) || c.children.isNotEmpty || !canEditCollabNode(state, c),
      )) {
    return false;
  }
  final tx = state.transaction
    ..deleteNode(node)
    ..afterSelection = null;
  if (node.parent!.children.length == 1) tx.insertNode(node.path, paragraphNode());
  if (state.undoManager.undoStack.isNonEmpty) state.undoManager.undoStack.last.seal();
  await state.apply(tx, withUpdateSelection: false, skipHistoryDebounce: true);
  return true;
}
