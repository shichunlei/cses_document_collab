import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/model/collab_mermaid_options.dart';

/// 桌面绘图容器；源码由唯一 mermaid-textarea 子节点持有。
const collabMermaidType = 'mermaid';

/// 桌面纯文本源码子块，不允许单独插入正文。
const collabMermaidSourceType = 'mermaid-textarea';

/// 与桌面绘图能力一致的源码 UTF-16 长度上限。
const collabMermaidMaxLength = 100000;

/// 新绘图草稿，不在打开面板时写入文档。
const collabMermaidTemplate = 'flowchart TD\n  A[开始] --> B[完成]';

/// 可独立撤销的视图字段；wrapper 区分缺失、null 和字符串。
const collabMermaidModeAttribute = 'cses_mermaid_mode';

/// 从 [attributes] 读取原始 mode；[edited] 表示本次明确修改此字段。
/// 未知值保留于投影，只有用户主动选择模式时才写入新的有效值。
CollabResource readCollabMermaidProperties(
  Map<String, dynamic> attributes, {
  bool edited = false,
}) {
  final raw = attributes[collabResourceAttribute];
  final base = raw is Map
      ? CollabResource.fromJson(Map<String, dynamic>.from(raw))
      : const CollabResource();
  final field = attributes[collabMermaidModeAttribute];
  if (field is! String) return base;
  final wrapper = jsonDecode(field) as Map<String, dynamic>;
  final values = base.values;
  if (wrapper.containsKey('value')) {
    values['mode'] = wrapper['value'];
  } else {
    values.remove('mode');
  }
  return CollabResource.fromValues(
    values,
    edits: edited ? jsonEncode({'mode': wrapper}) : null,
  );
}

/// 将借用的 [resource] 投影为原始快照及可撤销的 mode 字段。
Map<String, dynamic> collabMermaidNodeAttributes(CollabResource resource) => {
  collabResourceAttribute: resource.toJson(),
  collabMermaidModeAttribute: resource.field('mode'),
};

/// 解析借用 [node] 的共享视图，未知或缺失只作展示回落。
CollabMermaidView collabMermaidView(Node node) => CollabMermaidView.parse(
  readCollabMermaidProperties(node.attributes).values['mode'],
);

/// 对借用 [editor] 中稳定 [id] 的绘图切换 [view]，不修改源码或未知属性。
/// 只读、关闭、删除、无变化返回 false；独立事务可撤销，失败透传。
Future<bool> changeCollabMermaidView(
  EditorState editor,
  String id,
  CollabMermaidView view,
) async {
  if (editor.isDisposed || !editor.editable) return false;
  final node = findCollabMermaid(editor, id);
  if (collabMermaidSource(node) == null) return false;
  final field = jsonEncode({'value': view.value});
  if (node!.attributes[collabMermaidModeAttribute] == field) return false;
  if (editor.undoManager.undoStack.isNonEmpty) {
    editor.undoManager.undoStack.last.seal();
  }
  await editor.apply(
    editor.transaction..updateNode(node, {collabMermaidModeAttribute: field}),
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
  return true;
}

/// 从借用 [editor] 按稳定 [id] 查找绘图容器；关闭或删除返回 null。
Node? findCollabMermaid(EditorState editor, String id) {
  if (editor.isDisposed) return null;

  /// 在借用 [node] 子树递归查找，不保留路径引用。
  Node? visit(Node node) {
    if (node.type == collabMermaidType &&
        (node.attributes['cses_collab_block_id'] ?? node.id) == id) {
      return node;
    }
    for (final child in node.children) {
      final found = visit(child);
      if (found != null) return found;
    }
    return null;
  }

  return visit(editor.document.root);
}

/// 返回借用 [node] 的唯一源码子块；异常或未适配子树返回 null。
Node? collabMermaidSource(Node? node) =>
    node?.type == collabMermaidType &&
        node!.children.length == 1 &&
        node.children.single.type == collabMermaidSourceType &&
        node.children.single.delta != null
    ? node.children.single
    : null;

/// 将 [source] 保存至借用 [editor] 中稳定 [id] 的源码子块。
/// [expectedSourceId] 和 [expectedDelta] 是面板打开时的身份及完整正文快照；
/// 身份、原文或格式变化后拒绝覆盖。只读、关闭、超限、失效或无变化返回 false。
/// [view] 非 null 时原子保存视图；[expectedModeField] 非 null 时也核对原始视图字段。
/// 使用独立文本增量事务，完成后可撤销；远端源码/结构变化由适配器清除过期历史；事务异常透传，编辑器仍由页面释放。
Future<bool> changeCollabMermaid(
  EditorState editor,
  String id,
  String source, {
  required String expectedSourceId,
  required String expectedDelta,
  CollabMermaidView? view,
  String? expectedModeField,
}) async {
  if (editor.isDisposed ||
      !editor.editable ||
      source.length > collabMermaidMaxLength) {
    return false;
  }
  final container = findCollabMermaid(editor, id);
  final node = collabMermaidSource(container);
  if (node == null ||
      node.id != expectedSourceId ||
      jsonEncode(node.delta!.toJson()) != expectedDelta ||
      (expectedModeField != null &&
          container!.attributes[collabMermaidModeAttribute] !=
              expectedModeField)) {
    return false;
  }
  final modeField = view == null ? null : jsonEncode({'value': view.value});
  final textChanged = node.delta!.toPlainText() != source;
  final modeChanged =
      modeField != null &&
      container!.attributes[collabMermaidModeAttribute] != modeField;
  if (!textChanged && !modeChanged) return false;
  if (editor.undoManager.undoStack.isNonEmpty) {
    editor.undoManager.undoStack.last.seal();
  }
  final before = node.delta!;
  final patch = before.diff(Delta()..insert(source));
  final transaction = editor.transaction;
  if (textChanged) {
    transaction.add(
      UpdateTextOperation(node.path, patch, patch.invert(before)),
    );
  }
  if (modeChanged) {
    transaction.updateNode(container, {collabMermaidModeAttribute: modeField});
  }
  await editor.apply(
    transaction,
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
  return true;
}

/// 在借用 [editor] 的保存 [selection] 起点插入 [source]，返回后置段落光标。
/// 仅支持根/高亮内普通正文；空段落替换，非空段落完整保留。
/// [view] 是新块的共享视图，默认仅预览；
/// 容器及源码分别使用新身份，同一事务支持整体撤销。只读、关闭、无效位置或超限返回 null。
Future<Selection?> insertCollabMermaid(
  EditorState editor,
  Selection selection,
  String source, {
  CollabMermaidView view = CollabMermaidView.graph,
}) async {
  if (editor.isDisposed ||
      !editor.editable ||
      source.length > collabMermaidMaxLength ||
      selection.start.path.isEmpty) {
    return null;
  }
  final anchor = editor.getNodeAtPath(selection.start.path);
  if (anchor == null ||
      anchor.delta == null ||
      !const {'page', 'callout'}.contains(anchor.parent?.type)) {
    return null;
  }
  final text = Node(
    type: collabMermaidSourceType,
    attributes: {blockComponentDelta: (Delta()..insert(source)).toJson()},
  );
  text.updateAttributes({'cses_collab_block_id': text.id});
  final diagram = Node(type: collabMermaidType, children: [text]);
  diagram.updateAttributes({
    'cses_collab_block_id': diagram.id,
    ...collabMermaidNodeAttributes(
      CollabResource.fromValues({'mode': view.value}),
    ),
  });
  final empty = anchor.delta!.toPlainText().isEmpty;
  final path = empty ? anchor.path : anchor.path.next;
  final landing = paragraphNode();
  landing.updateAttributes({'cses_collab_block_id': landing.id});
  final transaction = editor.transaction
    ..insertNodes(path, [diagram, landing], deepCopy: false);
  if (empty) transaction.deleteNode(anchor);
  if (editor.undoManager.undoStack.isNonEmpty) {
    editor.undoManager.undoStack.last.seal();
  }
  await editor.apply(transaction, skipHistoryDebounce: true);
  return Selection.single(path: path.next, startOffset: 0);
}

/// 删除借用 [editor] 中稳定 [id] 的完整绘图；最后一个兄弟补空段落。
/// 只读、关闭、无效结构或父容器不支持时不写入；保留独立撤销边界，异常透传。
Future<void> deleteCollabMermaid(EditorState editor, String id) async {
  if (editor.isDisposed || !editor.editable) return;
  final node = findCollabMermaid(editor, id);
  if (collabMermaidSource(node) == null ||
      !const {'page', 'callout'}.contains(node?.parent?.type)) {
    return;
  }
  final path = node!.path;
  final transaction = editor.transaction
    ..add(DeleteOperation(path, [node]), transform: false)
    ..afterSelection = null;
  if (node.parent!.children.length == 1) {
    final paragraph = paragraphNode();
    paragraph.updateAttributes({'cses_collab_block_id': paragraph.id});
    transaction.add(InsertOperation(path, [paragraph]), transform: false);
  }
  if (editor.undoManager.undoStack.isNonEmpty) {
    editor.undoManager.undoStack.last.seal();
  }
  await editor.apply(
    transaction,
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
}
