import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/services.dart';

import 'guidance_entries.dart';

/// 业务行回车扩展：结束业务行后回到普通正文，其余输入交给共用编辑器。
final journalParagraphEnter = CharacterShortcutEvent(
  key: 'journal-paragraph-enter',
  character: '\n',
  handler: _handleEnter,
);

/// 在借用的[state]中处理业务行非Shift回车，保留选区及独立撤销步骤。
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
  return false;
}
