import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter/services.dart';

import 'journal_draft.dart';
import 'guidance_entries.dart';

/// 日记回车入口：结束业务行后回到普通正文，空列表转回段落，其余复用段落拆分。
final journalParagraphEnter = CharacterShortcutEvent(
  key: 'journal-paragraph-enter',
  character: '\n',
  handler: _handleEnter,
);

/// 在借用的[state]中处理非Shift回车；空列表在原栏目/路径内转换，保留选区及独立撤销步骤。
/// 不接管已关闭、只读或非适用选区；普通段落、非空列表和软换行交给原段落输入链。
Future<bool> _handleEnter(EditorState state) async {
  if (state.isDisposed || !state.editable) return false;
  final selection = state.selection;
  final node = selection == null
      ? null
      : state.getNodeAtPath(selection.start.path);
  if (!HardwareKeyboard.instance.isShiftPressed &&
      selection != null &&
      selection.isSingle &&
      node != null &&
      node.attributes[guidanceEntryAttribute] != null) {
    final range = selection.normalized;
    final transaction = state.transaction
      ..updateNode(node, {
        blockComponentDelta: node.delta!.slice(0, range.start.offset).toJson(),
      });
    transaction.add(
      InsertOperation(node.path.next, [
        paragraphNode(delta: node.delta!.slice(range.end.offset)),
      ]),
      transform: false,
    );
    transaction
      ..afterSelection = Selection.collapsed(Position(path: node.path.next))
      ..selectionExtraInfo = {}
      ..customSelectionType = SelectionType.inline;
    if (state.undoManager.undoStack.isNonEmpty) {
      state.undoManager.undoStack.last.seal();
    }
    await state.apply(transaction, skipHistoryDebounce: true);
    return true;
  }
  if (!HardwareKeyboard.instance.isShiftPressed &&
      selection != null &&
      selection.isCollapsed &&
      selection.start.offset == 0 &&
      node != null &&
      node.parent?.type == journalSectionType &&
      node.delta?.isEmpty == true &&
      const {
        BulletedListBlockKeys.type,
        NumberedListBlockKeys.type,
        TodoListBlockKeys.type,
      }.contains(node.type)) {
    final attributes = {...node.attributes}..remove(TodoListBlockKeys.checked);
    final transaction = state.transaction;
    transaction.add(DeleteOperation(node.path, [node]), transform: false);
    transaction.add(
      InsertOperation(node.path, [
        node.copyWith(type: ParagraphBlockKeys.type, attributes: attributes),
      ]),
      transform: false,
    );
    transaction
      ..afterSelection = selection
      ..selectionExtraInfo = {}
      ..customSelectionType = SelectionType.inline;
    if (state.undoManager.undoStack.isNonEmpty) {
      state.undoManager.undoStack.last.seal();
    }
    await state.apply(transaction, skipHistoryDebounce: true);
    return true;
  }
  return handleDocumentParagraphEnter(state);
}
