import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/native/api/collab/history.dart' as native;

/// Convert borrowed [selection] in [state] to stable block IDs under [idAttribute].
/// Missing identities return null; no native calls or document mutations occur.
native.HistorySelection? captureNativeEditorSelection(EditorState state, Selection? selection, String idAttribute) {
  if (selection == null || state.isDisposed) return null;
  native.HistoryPoint? point(Position position) {
    final node = state.getNodeAtPath(position.path);
    final id = node?.attributes[idAttribute];
    if (id is! String || position.offset < 0) return null;
    return native.HistoryPoint(blockId: id, offset: position.offset);
  }

  final anchor = point(selection.start);
  final focus = point(selection.end);
  return anchor == null || focus == null ? null : native.HistorySelection(anchor: anchor, focus: focus);
}

/// Restore resolved [selection] in borrowed [state] using current [idAttribute]
/// identities. Reorder/nesting uses current paths; absent endpoints clear the
/// selection. UTF-16 offsets are bounded and never split a surrogate pair.
/// This does not request focus, open a keyboard, write content or create history.
void restoreNativeEditorSelection(EditorState state, native.HistorySelection? selection, String idAttribute) {
  if (state.isDisposed) return;
  final nodes = <String, Node>{};
  void visit(Node node) {
    final id = node.attributes[idAttribute];
    if (id is String) nodes[id] = node;
    for (final child in node.children) {
      visit(child);
    }
  }

  for (final node in state.document.root.children) {
    visit(node);
  }
  Position? point(native.HistoryPoint value) {
    final node = nodes[value.blockId];
    if (node == null) return null;
    final text = node.delta?.toPlainText() ?? '';
    var offset = value.offset.clamp(0, text.length);
    if (offset > 0 &&
        offset < text.length &&
        text.codeUnitAt(offset - 1) >= 0xd800 &&
        text.codeUnitAt(offset - 1) <= 0xdbff &&
        text.codeUnitAt(offset) >= 0xdc00 &&
        text.codeUnitAt(offset) <= 0xdfff) {
      offset--;
    }
    return Position(path: List<int>.from(node.path), offset: offset);
  }

  final anchor = selection == null ? null : point(selection.anchor);
  final focus = selection == null ? null : point(selection.focus);
  state.selection = anchor == null || focus == null ? null : Selection(start: anchor, end: focus);
}
