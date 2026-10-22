import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_native_selection.dart';
import 'package:cses_document_collab/src/native/api/collab/history.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verify stable selection mapping independently of FFI, layout and old paths.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('directional nested endpoints resolve against current paths', () {
    final first = _paragraph('p', '你好');
    final second = _paragraph('q', '再见');
    final state = EditorState(
      document: Document(
        root: Node(
          type: 'page',
          children: [
            Node(type: 'callout', children: [second]),
            first,
          ],
        ),
      ),
    );
    try {
      const selection = HistorySelection(
        anchor: HistoryPoint(blockId: 'p', offset: 2),
        focus: HistoryPoint(blockId: 'q', offset: 1),
      );
      restoreNativeEditorSelection(state, selection, 'stable');
      expect(
        state.selection,
        Selection(
          start: Position(path: [1], offset: 2),
          end: Position(path: [0, 0], offset: 1),
        ),
      );
      expect(captureNativeEditorSelection(state, state.selection, 'stable'), selection);
    } finally {
      state.dispose();
    }
  });

  test('restore bounds UTF16 endpoints and never substitutes an absent block', () {
    final state = EditorState(
      document: Document(
        root: Node(type: 'page', children: [_paragraph('p', '你😀好')]),
      ),
    );
    try {
      restoreNativeEditorSelection(
        state,
        const HistorySelection(
          anchor: HistoryPoint(blockId: 'p', offset: 2),
          focus: HistoryPoint(blockId: 'p', offset: 99),
        ),
        'stable',
      );
      expect(state.selection, Selection.single(path: [0], startOffset: 1, endOffset: 4));
      restoreNativeEditorSelection(
        state,
        const HistorySelection(
          anchor: HistoryPoint(blockId: 'deleted', offset: 0),
          focus: HistoryPoint(blockId: 'p', offset: 1),
        ),
        'stable',
      );
      expect(state.selection, isNull);
    } finally {
      state.dispose();
    }
  });
}

/// Create a text node with stable [id] and UTF-16 [text] for path mapping tests.
Node _paragraph(String id, String text) => paragraphNode(text: text)..updateAttributes({'stable': id});
