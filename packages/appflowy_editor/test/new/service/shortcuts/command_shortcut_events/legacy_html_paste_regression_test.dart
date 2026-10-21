import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verifies caret, formatting and history of the retained legacy paste API.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'consecutive HTML paste advances caret and preserves suffix and formatting',
    () {
      final state = EditorState(
        document: Document(
          root: pageNode(children: [paragraphNode(text: 'abcd')]),
        ),
      );
      try {
        state.selection = Selection.collapsed(Position(path: [0], offset: 2));
        pasteHTML(state, '<p><strong>X</strong></p>');
        expect(state.document.first!.delta!.toPlainText(), 'abXcd');
        expect(
          state.selection,
          Selection.collapsed(Position(path: [0], offset: 3)),
        );
        state.undoManager.undoStack.last.seal();
        pasteHTML(state, '<p>Y</p>');
        expect(state.document.first!.delta!.toPlainText(), 'abXYcd');
        expect(
          state.selection,
          Selection.collapsed(Position(path: [0], offset: 4)),
        );
        expect(
          state.document.first!.delta!
              .slice(2, 3)
              .first
              .attributes?[AppFlowyRichTextKeys.bold],
          isTrue,
        );
        state.undoManager.undo();
        expect(state.document.first!.delta!.toPlainText(), 'abXcd');
        state.undoManager.redo();
        expect(state.document.first!.delta!.toPlainText(), 'abXYcd');
      } finally {
        state.dispose();
      }
    },
  );
}
