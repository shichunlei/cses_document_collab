import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verify delegated commands never replay a second path-based history.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'external owner suppresses local recording and receives undo/redo commands',
    () async {
      final editor = EditorState.blank(withInitialText: true);
      var undone = 0;
      var redone = 0;
      try {
        editor.undoManager.externalHistory = EditorHistoryDelegate(
          undo: () {
            undone++;
          },
          redo: () {
            redone++;
          },
          canUndo: () => true,
          canRedo: () => true,
        );
        await editor.apply(
          editor.transaction..insertText(editor.document.first!, 0, 'local'),
        );
        expect(editor.undoManager.undoStack.isEmpty, isTrue);
        editor.undoManager.undo();
        editor.undoManager.redo();
        expect(undone, 1);
        expect(redone, 1);
        expect(editor.document.first!.delta!.toPlainText(), 'local');
        editor.editable = false;
        editor.undoManager.undo();
        editor.undoManager.redo();
        expect(undone, 1);
        expect(redone, 1);
      } finally {
        editor.dispose();
      }
    },
  );

  test(
    'detaching owner cannot replay stale transactions and local undo still works',
    () async {
      final editor = EditorState.blank(withInitialText: true);
      try {
        await editor.apply(
          editor.transaction..insertText(editor.document.first!, 0, 'old'),
        );
        expect(editor.undoManager.canUndo, isTrue);
        editor.undoManager.externalHistory = EditorHistoryDelegate(
          undo: () {},
          redo: () {},
          canUndo: () => false,
          canRedo: () => false,
        );
        expect(editor.undoManager.canUndo, isFalse);
        editor.undoManager.undo();
        editor.undoManager.externalHistory = null;
        expect(editor.undoManager.undoStack.isEmpty, isTrue);
        await editor.apply(
          editor.transaction..insertText(editor.document.first!, 3, 'new'),
          skipHistoryDebounce: true,
        );
        editor.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        expect(editor.document.first!.delta!.toPlainText(), 'old');
      } finally {
        editor.dispose();
      }
    },
  );
}
