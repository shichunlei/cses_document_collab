import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_formula.dart';

/// AppFlowy 单字符投影上的 LaTeX 属性；不会作为格式属性写入桌面 Y.Text。
const collabInlineLatexAttribute = 'cses_inline_latex';

/// 行内对象的一个 UTF-16 光标位置；普通同字符文字不带 latex 时仍是文字。
const collabInlineFormulaCharacter = '\uFFFC';

/// 仅用于 AppFlowy 历史的稳定身份命令，不进入共享正文或桌面 props。
const collabInlineFormulaCommandAttribute = 'cses_inline_formula_command';

/// 保存行内公式的稳定块身份、单字符位置和打开时的定位文本。
/// 段落文字变化后拒绝陈旧位置；仅公式原文变化时可重新加载。
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/model/collab_inline_formula.dart';
/// final state = EditorState.blank();
/// final node = state.document.first!;
/// final target = CollabInlineFormulaTarget.capture(node, 0);
/// // target 为 null 时该位置没有公式；state 由创建方释放。
/// state.dispose();
/// ```
final class CollabInlineFormulaTarget {
  /// 私有构造；[blockId] 是稳定身份，[offset] 为 UTF-16 索引，[plainText] 用于拒绝过期位置。
  const CollabInlineFormulaTarget._(this.blockId, this.offset, this.plainText);

  /// 所在文字块的稳定协同 ID，不持有可失效的 Node 引用。
  final String blockId;

  /// 打开时公式占位字符的 UTF-16 索引。
  final int offset;

  /// 打开时包含单字符对象投影的整段文字，不包含 LaTeX 源码。
  final String plainText;

  /// 从借用 [node] 的 [offset] 捕获一个公式；非公式或无正文位置返回 null。
  static CollabInlineFormulaTarget? capture(Node node, int offset) {
    if (collabInlineLatexAt(node, offset) == null) return null;
    return CollabInlineFormulaTarget._(
      node.attributes['cses_collab_block_id'] as String? ?? node.id,
      offset,
      node.delta!.toPlainText(),
    );
  }

  /// 在借用 [state] 中重新定位；关闭、删除、文本位置变化或对象已消失返回 null。
  Node? resolve(EditorState state) {
    final node = findCollabInlineTextNode(state, blockId);
    return node?.delta?.toPlainText() == plainText && node != null && collabInlineLatexAt(node, offset) != null
        ? node
        : null;
  }
}

/// 在借用 [state] 中按稳定 [id] 找文字节点；销毁/删除时返回 null。
Node? findCollabInlineTextNode(EditorState state, String id) {
  if (state.isDisposed) return null;

  /// 读取借用 [node] 及子树，不保存旧节点引用。
  Node? visit(Node node) {
    if ((node.attributes['cses_collab_block_id'] ?? node.id) == id) return node;
    for (final child in node.children) {
      final found = visit(child);
      if (found != null) return found;
    }
    return null;
  }

  final node = visit(state.document.root);
  return node?.delta != null ? node : null;
}

/// 返回借用 [node] 在 UTF-16 [offset] 的公式原文，空字符串是合法的已存在对象。
/// 普通 U+FFFC、负索引及越界返回 null；不会改写未知属性。
String? collabInlineLatexAt(Node node, int offset) {
  if (offset < 0) return null;
  var cursor = 0;
  for (final operation in node.delta?.whereType<TextInsert>() ?? <TextInsert>[]) {
    final relative = offset - cursor;
    final latex = operation.attributes?[collabInlineLatexAttribute];
    if (relative >= 0 && relative < operation.length) {
      return operation.text[relative] == collabInlineFormulaCharacter && latex is String ? latex : null;
    }
    cursor += operation.length;
  }
  return null;
}

/// 在借用 [state] 的同块 [selection] 位置插入 [latex]，范围选区被原子对象替换。
/// 空/超长原文、跨块、代码块、只读或失效位置返回 null；返回公式后的光标，不恢复焦点。
/// 命令独立记录历史，执行前按稳定块身份核对定位文字与被替换片段。
Future<Selection?> insertCollabInlineFormula(EditorState state, Selection selection, String latex) async {
  if (state.isDisposed ||
      !state.editable ||
      latex.isEmpty ||
      latex.length > collabFormulaMaxLength ||
      !selection.isSingle) {
    return null;
  }
  final normalized = selection.normalized;
  final node = state.getNodeAtPath(normalized.start.path);
  final delta = node?.delta;
  if (node == null || delta == null || node.type == 'code') return null;
  final start = normalized.start.offset;
  final end = normalized.end.offset;
  if (start < 0 || end < start || end > delta.length) return null;
  final after = Delta()..insert(collabInlineFormulaCharacter, attributes: {collabInlineLatexAttribute: latex});
  await applyCollabInlineCommand(state, node, start, delta.slice(start, end), after);
  return Selection.single(path: node.path, startOffset: start + 1);
}

/// 修改借用 [state] 的稳定 [target]；[latex] 为空删除一个对象。
/// [expectedLatex] 是编辑草稿依据的原文，拒绝覆盖远端变化；相同值不生成历史。
/// 关闭、只读、目标删除/定位文字变化或超长输入返回 false；事务异常透传。
Future<bool> changeCollabInlineFormula(
  EditorState state,
  CollabInlineFormulaTarget target,
  String latex, {
  required String expectedLatex,
}) async {
  if (state.isDisposed || !state.editable || latex.length > collabFormulaMaxLength) {
    return false;
  }
  final node = target.resolve(state);
  if (node == null ||
      collabInlineLatexAt(node, target.offset) != expectedLatex ||
      (latex.isNotEmpty && latex == expectedLatex)) {
    return false;
  }
  final before = node.delta!.slice(target.offset, target.offset + 1);
  final after = Delta();
  if (latex.isNotEmpty) {
    final attrs = Map<String, dynamic>.from(before.first.attributes ?? {});
    attrs[collabInlineLatexAttribute] = latex;
    after.insert(collabInlineFormulaCharacter, attributes: attrs);
  }
  await applyCollabInlineCommand(state, node, target.offset, before, after);
  return true;
}

/// 为公式或四类提及对象在借用 [state]/[node] 的 [offset] 生成正反命令，替换 [before] 为 [after]。
/// 只记录该区间；真正的 Delta 在适配器 before 阶段据最新节点计算，避免历史覆盖其他属性。
/// 必须在已安装命令解析的适配器中调用，事务完成后返回，异常透传；不恢复焦点。
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
/// import 'package:cses_document_collab/src/model/collab_inline_formula.dart';
/// Future<void> replaceAtom() async {
///   final adapter = AppFlowyBlockEditorAdapter(initialBlocks: const [
///     CollabEditorBlock(id: 'p', blockType: 'paragraph', text: 'A'),
///   ], onLocalBlocksChanged: (_) {});
///   try {
///     final state = adapter.editorState;
///     await applyCollabInlineCommand(state, state.document.first!, 0,
///       Delta()..insert('A'), Delta()..insert(collabInlineFormulaCharacter,
///         attributes: {collabInlineLatexAttribute: 'x^2'}));
///   } finally {
///     adapter.dispose();
///   }
/// }
/// ```
Future<void> applyCollabInlineCommand(EditorState state, Node node, int offset, Delta before, Delta after) async {
  final base = node.delta!;
  final next = base.compose(
    Delta()
      ..retain(offset)
      ..delete(before.length)
      ..addAll(after),
  );
  final id = node.attributes['cses_collab_block_id'] as String? ?? node.id;

  /// 编码 [text] 对应定位文本以及 [from]/[to] 的局部正反操作。
  String command(String text, Delta from, Delta to) =>
      jsonEncode({'id': id, 'offset': offset, 'text': text, 'from': from.toJson(), 'to': to.toJson()});

  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  await state.apply(
    state.transaction..add(
      UpdateOperation(
        node.path,
        {collabInlineFormulaCommandAttribute: command(base.toPlainText(), before, after)},
        {collabInlineFormulaCommandAttribute: command(next.toPlainText(), after, before)},
      ),
    ),
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
}

/// 在借用 [state] 的 [transaction] 执行前解析公式及四类提及对象命令及撤销/重做。
/// 按稳定块 ID 重定位；文本或目标内容被远端改动、权限撤销时丢弃陈旧操作，保留其他历史。
/// 仅替换局部区间并保留当前其他格式，不执行事务、不拥有编辑器。
void resolveCollabInlineFormulaCommands(EditorState state, Transaction transaction) {
  final result = <Operation>[];
  var hasCommand = false;
  for (final operation in transaction.operations) {
    if (operation is! UpdateOperation || !operation.attributes.containsKey(collabInlineFormulaCommandAttribute)) {
      result.add(operation);
      continue;
    }
    hasCommand = true;
    if (state.isDisposed || !state.editable) continue;
    final raw = operation.attributes[collabInlineFormulaCommandAttribute];
    if (raw is! String) continue;
    final command = jsonDecode(raw) as Map<String, dynamic>;
    final node = findCollabInlineTextNode(state, command['id'] as String);
    final base = node?.delta;
    final offset = command['offset'] as int;
    final before = Delta.fromJson(command['from']);
    final after = Delta.fromJson(command['to']);
    if (node == null ||
        base == null ||
        base.toPlainText() != command['text'] ||
        offset < 0 ||
        offset + before.length > base.length ||
        base.slice(offset, offset + before.length) != before) {
      continue;
    }
    final next = base.compose(
      Delta()
        ..retain(offset)
        ..delete(before.length)
        ..addAll(after),
    );
    result.add(
      UpdateOperation(
        node.path,
        {collabInlineFormulaCommandAttribute: raw, 'delta': next.toJson()},
        {
          collabInlineFormulaCommandAttribute: operation.oldAttributes[collabInlineFormulaCommandAttribute],
          'delta': base.toJson(),
        },
      ),
    );
  }
  if (hasCommand) {
    transaction.operations = result;
    transaction.beforeSelection = state.selection;
    transaction.afterSelection = state.selection;
  }
}
