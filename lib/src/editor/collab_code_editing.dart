import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:flutter/services.dart';

/// 代码块的普通回车入口，置于标准字符快捷键之前，软/硬键盘共用。
/// 借用编辑器并在原节点内换行，不持有资源；Shift 交给既有输入处理。
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_code_editing.dart';
/// final state = EditorState.blank(); // 宿主负责 state.dispose()。
/// final editor = AppFlowyEditor(editorState: state,
///   characterShortcutEvents: [collabCodeEnter, ...standardCharacterShortcutEvents]);
/// ```
final collabCodeEnter = CharacterShortcutEvent(
  key: 'cses-code-enter',
  character: '\n',
  handler: handleCollabCodeEnter,
);

/// 在借用 [state] 的同一代码节点内替换选中文字并插入换行，保留节点身份、属性和其余 Delta。
/// 与桌面代码输入规则一致，延续光标前当前行的 Tab 数量；空块及连续回车也不拆分节点。
/// 仅接管有效的单节点文字选区，支持容器内代码；只读、销毁、Shift、块选区、跨节点
/// 或非代码选区返回 false。一次事务可独立撤销，光标落在新行缩进后并清除临时手势选区。
/// Future 在事务应用后返回 true；事务异常向输入边界传播，不创建焦点或异步后台资源。
Future<bool> handleCollabCodeEnter(EditorState state) async {
  if (state.isDisposed ||
      !state.editable ||
      state.selectionType == SelectionType.block ||
      HardwareKeyboard.instance.isShiftPressed) {
    return false;
  }
  final selection = state.selection?.normalized;
  if (selection == null || !selection.isSingle) return false;
  final node = state.getNodeAtPath(selection.start.path);
  final delta = node?.delta;
  if (node == null ||
      node.type != csesCodeBlockType ||
      node.children.isNotEmpty ||
      delta == null ||
      selection.start.offset < 0 ||
      selection.end.offset > delta.length) {
    return false;
  }
  final offset = selection.start.offset;
  final line = delta.toPlainText().substring(0, offset).split('\n').last;
  final newline = '\n${'\t' * (line.split('\t').length - 1)}';
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  final transaction = buildCollabCodeTextReplacement(state, selection, newline);
  if (transaction == null) return false;
  await state.apply(transaction, skipHistoryDebounce: true);
  return true;
}

/// 为借用的[state]在[selection]处替换纯文本[text]，代码换行与粘贴共用此原位事务。
/// 仅接受可编辑代码叶子的有效单节点选区，失效、块选区或对象占位返回null。
/// 不应用事务或修改历史；调用方先核对容量/策略，再apply并拥有独立历史边界。
/// 保留节点身份和全部代码属性，光标落在插入文本末尾，空文本可删除所选内容。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_code_editing.dart';
/// final state = EditorState(document: Document(root: pageNode(children: [
///   Node(type: 'code', attributes: {blockComponentDelta: Delta().toJson()}),
/// ])));
/// final selection = Selection.collapsed(Position(path: [0]));
/// state.selection = selection;
/// final transaction = buildCollabCodeTextReplacement(state, selection, 'a\nb');
/// if (transaction != null) await state.apply(transaction);
/// state.dispose();
/// ```
Transaction? buildCollabCodeTextReplacement(EditorState state, Selection selection, String text) {
  if (state.isDisposed ||
      !state.editable ||
      state.selectionType == SelectionType.block ||
      !selection.isSingle ||
      text.contains('\uFFFC')) {
    return null;
  }
  final range = selection.normalized;
  final node = state.getNodeAtPath(range.start.path);
  final delta = node?.delta;
  if (node == null ||
      node.type != csesCodeBlockType ||
      node.children.isNotEmpty ||
      delta == null ||
      range.start.offset < 0 ||
      range.end.offset > delta.length) {
    return null;
  }
  return state.transaction
    ..deleteText(node, range.start.offset, range.end.offset - range.start.offset)
    ..insertText(node, range.start.offset, text, attributes: {})
    ..afterSelection = Selection.collapsed(Position(path: node.path, offset: range.start.offset + text.length))
    ..selectionExtraInfo = {}
    ..customSelectionType = SelectionType.inline;
}
