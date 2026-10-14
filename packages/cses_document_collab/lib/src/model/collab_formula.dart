import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';

/// 桌面公式的正式无正文块类型。
const collabFormulaType = 'formula';

/// LaTeX 独立历史字段；JSON wrapper 区分缺失、null 和空字符串。
const collabFormulaAttribute = 'cses_formula_latex';

/// 与桌面公式能力契约一致的 UTF-16 长度上限。
const collabFormulaMaxLength = 20000;

/// 从借用 [attributes] 读取公式属性；[edited] 为 true 时只生成 latex 补丁。
/// 展示回落不写权威数据，缺失与显式 null 在撤销时保持区分。
CollabResource readCollabFormula(
  Map<String, dynamic> attributes, {
  bool edited = false,
}) {
  final raw = attributes[collabResourceAttribute];
  final resource = raw is Map
      ? CollabResource.fromJson(Map<String, dynamic>.from(raw))
      : const CollabResource();
  final field = attributes[collabFormulaAttribute];
  if (field is! String) return resource;
  final wrapper = jsonDecode(field) as Map<String, dynamic>;
  final values = resource.values;
  if (wrapper.containsKey('value')) {
    values['latex'] = wrapper['value'];
  } else {
    values.remove('latex');
  }
  return CollabResource.fromValues(
    values,
    edits: edited ? jsonEncode({'latex': wrapper}) : null,
  );
}

/// 将 [resource] 的原始公式属性投影为独立可撤销的编辑器字段。
Map<String, dynamic> collabFormulaNodeAttributes(CollabResource resource) => {
  collabResourceAttribute: resource.toJson(),
  collabFormulaAttribute: resource.field('latex'),
};

/// 按稳定 [id] 在借用 [state] 的完整树中查找公式，关闭或删除返回 null。
Node? findCollabFormula(EditorState state, String id) {
  if (state.isDisposed) return null;

  /// 递归读取借用 [node]，不保存可能随远端投影失效的引用。
  Node? visit(Node node) {
    if ((node.attributes['cses_collab_block_id'] ?? node.id) == id &&
        node.type == collabFormulaType) {
      return node;
    }
    for (final child in node.children) {
      final found = visit(child);
      if (found != null) return found;
    }
    return null;
  }

  return visit(state.document.root);
}

/// 对借用 [state] 的稳定 [id] 提交 [latex] 原文；空字符串保留空公式。
/// [expectedField] 非 null 时拒绝覆盖已经变化的远端属性 wrapper。
/// 只读、关闭、删除、超过 20000 UTF-16 单元或内容相同返回 false。
/// 不校验 TeX 方言语法，以便保留桌面可渲染但本地不支持的表达式；事务异常透传。
Future<bool> changeCollabFormula(
  EditorState state,
  String id,
  String latex, {
  String? expectedField,
}) async {
  if (state.isDisposed ||
      !state.editable ||
      latex.length > collabFormulaMaxLength) {
    return false;
  }
  final node = findCollabFormula(state, id);
  if (node == null ||
      (expectedField != null &&
          node.attributes[collabFormulaAttribute] != expectedField)) {
    return false;
  }
  final next = jsonEncode({'value': latex});
  if (node.attributes[collabFormulaAttribute] == next) return false;
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  await state.apply(
    state.transaction..add(
      UpdateOperation(
        node.path,
        {
          collabFormulaAttribute: next,
          collabResourceTargetAttribute: id,
          collabResourceKindAttribute: collabFormulaType,
        },
        {
          collabFormulaAttribute: node.attributes[collabFormulaAttribute],
          collabResourceTargetAttribute: id,
          collabResourceKindAttribute: collabFormulaType,
        },
      ),
    ),
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
  return true;
}

/// 在借用 [state] 的保存 [selection] 起点插入 [latex]，返回后置段落光标。
/// 空正文被替换，非空正文保留；支持根与高亮容器，公式使用独立身份。
/// 只读、关闭、无效位置或超长表达式返回 null；焦点由面板退场后的调用方恢复。
Future<Selection?> insertCollabFormula(
  EditorState state,
  Selection selection,
  String latex,
) async {
  if (state.isDisposed ||
      !state.editable ||
      selection.start.path.isEmpty ||
      latex.length > collabFormulaMaxLength) {
    return null;
  }
  final source = state.getNodeAtPath(selection.start.path);
  if (source == null ||
      !const {'page', 'callout'}.contains(source.parent?.type)) {
    return null;
  }
  final formula = Node(
    type: collabFormulaType,
    attributes: collabFormulaNodeAttributes(
      CollabResource.fromValues({'latex': latex}),
    ),
  );
  formula.updateAttributes({'cses_collab_block_id': formula.id});
  final empty = source.delta?.toPlainText().isEmpty == true;
  final path = empty ? source.path : source.path.next;
  final transaction = state.transaction
    ..insertNodes(path, [formula, paragraphNode()], deepCopy: false);
  if (empty) transaction.deleteNode(source);
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  await state.apply(transaction, skipHistoryDebounce: true);
  return Selection.single(path: path.next, startOffset: 0);
}
