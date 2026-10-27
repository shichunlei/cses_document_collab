import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';

/// 桌面分栏族的无正文容器类型。
const collabColumnsTypes = {'columns', 'column'};

/// 分栏布局的独立可撤销字段；列索引仅保留桌面数据，不用于定位。
const collabColumnsKeys = {'columnCount', 'columnWidths', 'columnIndex'};

/// 返回[property]对应的本地字段键，值使用value包装保留缺失与null的差异。
String columnsPropertyAttribute(String property) => 'cses_columns_$property';

/// 将借用[resource]的布局映射为节点属性，不生成默认值或修改共享数据。
Map<String, dynamic> columnsNodeAttributes(CollabResource resource) => {
  collabResourceAttribute: resource.toJson(),
  for (final key in collabColumnsKeys) columnsPropertyAttribute(key): resource.field(key),
};

/// 读取借用[attributes]的分栏属性；[edited]指定本次显式修改的字段，默认不写回。
CollabResource readCollabColumns(Map<String, dynamic> attributes, {Set<String> edited = const {}}) {
  final raw = attributes[collabResourceAttribute];
  final values = raw is Map ? CollabResource.fromJson(Map<String, dynamic>.from(raw)).values : <String, dynamic>{};
  final edits = <String, dynamic>{};
  for (final key in collabColumnsKeys) {
    final field = attributes[columnsPropertyAttribute(key)];
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

/// 返回借用[node]的显示比例；非法或长度不符时均分，只影响展示，不修复共享属性。
List<double> collabColumnWidths(Node node) {
  final count = node.children.length;
  if (count == 0) return const [];
  final raw = readCollabColumns(node.attributes).values['columnWidths'];
  if (raw is! List || raw.length != count || raw.any((v) => v is! num || !v.isFinite || v <= 0)) {
    return List.filled(count, 100 / count);
  }
  final values = raw.cast<num>();
  final largest = values.reduce((a, b) => a > b ? a : b);
  final scaled = [for (final value in values) value / largest];
  final total = scaled.fold(0.0, (sum, value) => sum + value);
  final widths = [for (final value in scaled) value / total * 100];
  // 极端旧数据不扩张为无法滚动的巨型画布，且不改写作者属性。
  return widths.any((v) => !v.isFinite || v < .1) ? List.filled(count, 100 / count) : widths;
}

/// 创建调用方拥有的[count]列分栏树，每列包含一个独立空段落；范围为2～8，越界抛RangeError。
Node createCollabColumns([int count = 2]) {
  RangeError.checkValueInInterval(count, 2, 8, 'count');
  final node = Node(
    type: 'columns',
    attributes: columnsNodeAttributes(
      CollabResource.fromValues({'columnCount': count, 'columnWidths': List.filled(count, 100 / count)}),
    ),
    children: [
      for (var i = 0; i < count; i++) Node(type: 'column', children: [paragraphNode()]),
    ],
  );
  node.updateAttributes({'cses_collab_block_id': node.id});
  return node;
}

/// 在借用[state]的[selection]所在根级或高亮段落后插入[count]列；空段落被替换。
/// 默认两列，返回首列光标；只读、锁定、失效选区或不支持的父级返回null，事务失败向上传播。
Future<Selection?> insertCollabColumns(EditorState state, Selection selection, {int count = 2}) async {
  if (state.isDisposed || !state.editable || !selection.isCollapsed) return null;
  final source = state.getNodeAtPath(selection.start.path);
  if (source == null || !const {'page', 'callout'}.contains(source.parent?.type) || !canEditCollabNode(state, source)) {
    return null;
  }
  final columns = createCollabColumns(count);
  final replace = source.type == 'paragraph' && source.delta?.isEmpty == true;
  final path = replace ? source.path : source.path.next;
  final landing = Selection.single(path: path + [0, 0], startOffset: 0);
  final tx = state.transaction;
  if (replace) tx.deleteNode(source);
  tx.insertNode(path, columns, deepCopy: false);
  tx.afterSelection = landing;
  if (!state.undoManager.undoStack.isEmpty) state.undoManager.undoStack.last.seal();
  await state.apply(tx, skipHistoryDebounce: true);
  return landing;
}

/// 按稳定[id]修改借用[state]中的分栏；[action]为add/remove/left/right/flatten/equal/widen。
/// [columnId]指定目标列；add时null追加到末尾，widen将目标列增加5个百分点。
/// 增减列同步均分宽度；删至一列时展开剩余正文。flatten保留全部后代身份及顺序。
/// 锁、关闭、失效身份、未知后代及边界操作返回false；一次事务构成独立历史，异常向上传播。
Future<bool> editCollabColumns(EditorState state, String id, String action, {String? columnId}) async {
  final node = findCollabActionNode(state, id);
  if (node == null || node.type != 'columns' || !_editableSubtree(state, node)) return false;
  if (node.children.any((c) => c.type != 'column')) return false;
  final count = node.children.length;
  final index = node.children.indexWhere((c) => (c.attributes['cses_collab_block_id'] ?? c.id) == columnId);
  final tx = state.transaction;
  var nextCount = count;
  List<double>? widths;
  if (action == 'flatten' || (action == 'remove' && count == 2 && index >= 0)) {
    final children = [
      for (var i = 0; i < count; i++)
        if (action == 'flatten' || i != index) ...node.children[i].children.map((c) => _cloneColumnContent(c)),
    ];
    tx.deleteNode(node);
    tx.insertNodes(node.path, children.isEmpty ? [paragraphNode()] : children, deepCopy: false);
  } else if (action == 'add' && count < 8 && (columnId == null || index >= 0)) {
    tx.insertNode(
      node.path + [columnId == null ? count : index + 1],
      Node(type: 'column', children: [paragraphNode()]),
      deepCopy: false,
    );
    nextCount++;
  } else if (action == 'remove' && count > 2 && index >= 0) {
    tx.deleteNode(node.children[index]);
    nextCount--;
  } else if ((action == 'left' || action == 'right') && index >= 0) {
    final target = index + (action == 'left' ? -1 : 1);
    if (target < 0 || target >= count) return false;
    final moving = _cloneColumnContent(node.children[index]);
    tx.deleteNode(node.children[index]);
    tx.add(InsertOperation(node.path + [target], [moving]), transform: false);
    widths = collabColumnWidths(node);
    final width = widths.removeAt(index);
    widths.insert(target, width);
  } else if (action == 'equal' && count > 0) {
    widths = List.filled(count, 100 / count);
  } else if (action == 'widen' && count > 1 && index >= 0) {
    widths = collabColumnWidths(node);
    final other = index == count - 1 ? index - 1 : index + 1;
    if (widths[other] < 15) return false;
    widths[index] += 5;
    widths[other] -= 5;
  } else {
    return false;
  }
  if (action != 'flatten' && !(action == 'remove' && count == 2)) {
    widths ??= List.filled(nextCount, 100 / nextCount);
    final original = readCollabColumns(node.attributes).values;
    final rawWidths = original['columnWidths'];
    if (tx.operations.isEmpty &&
        original['columnCount'] == nextCount &&
        rawWidths is List &&
        rawWidths.length == widths.length &&
        List.generate(widths.length, (i) => rawWidths[i] == widths![i]).every((v) => v)) {
      return false;
    }
    final identity = {collabResourceTargetAttribute: id, collabResourceKindAttribute: 'columns'};
    tx.add(
      UpdateOperation(
        node.path,
        {
          ...identity,
          columnsPropertyAttribute('columnCount'): jsonEncode({'value': nextCount}),
          columnsPropertyAttribute('columnWidths'): jsonEncode({'value': widths}),
        },
        {
          ...identity,
          for (final key in ['columnCount', 'columnWidths'])
            columnsPropertyAttribute(key): node.attributes[columnsPropertyAttribute(key)] ?? jsonEncode({}),
        },
      ),
    );
  }
  tx.afterSelection = null;
  if (!state.undoManager.undoStack.isEmpty) state.undoManager.undoStack.last.seal();
  await state.apply(tx, withUpdateSelection: false, skipHistoryDebounce: true);
  return true;
}

/// 检查借用[state]中的[node]及全部后代可编辑，未知占位拒绝结构变更。
bool _editableSubtree(EditorState state, Node node) =>
    node.type != 'unsupported' &&
    canEditCollabNode(state, node) &&
    !(CollabBlockLocks.of(state)?.state(CollabBlockLocks.idOf(node)).containsLock ?? false) &&
    node.children.every((c) => _editableSubtree(state, c));

/// 深复制借用[node]并保留所有本地及协同身份，返回尚未挂接的独立子树。
Node _cloneColumnContent(Node node) => Node(
  type: node.type,
  id: node.id,
  attributes: Map<String, dynamic>.from(jsonDecode(jsonEncode(node.attributes)) as Map),
  children: node.children.map(_cloneColumnContent).toList(),
);
