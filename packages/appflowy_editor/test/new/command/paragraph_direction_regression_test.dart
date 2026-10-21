import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verifies paragraph direction through the public factory and newline command.
void main() {
  test(
    'paragraph factory preserves attribute direction without an override',
    () {
      final node = paragraphNode(
        attributes: {
          ParagraphBlockKeys.textDirection: blockComponentTextDirectionRTL,
        },
      );
      expect(
        node.attributes[ParagraphBlockKeys.textDirection],
        blockComponentTextDirectionRTL,
      );
    },
  );

  test('an explicit paragraph direction overrides inherited attributes', () {
    final node = paragraphNode(
      textDirection: blockComponentTextDirectionLTR,
      attributes: {
        ParagraphBlockKeys.textDirection: blockComponentTextDirectionRTL,
      },
    );
    expect(
      node.attributes[ParagraphBlockKeys.textDirection],
      blockComponentTextDirectionLTR,
    );
  });

  test(
    'newline keeps direction in both paragraph halves and through undo',
    () async {
      final state = EditorState(
        document: Document(
          root: pageNode(
            children: [
              paragraphNode(
                text: 'abcd',
                textDirection: blockComponentTextDirectionRTL,
              ),
            ],
          ),
        ),
      );
      try {
        state.selection = Selection.collapsed(Position(path: [0], offset: 2));
        await state.insertNewLine();
        expect(
          state.document.root.children.map((node) => node.delta!.toPlainText()),
          ['ab', 'cd'],
        );
        for (final node in state.document.root.children) {
          expect(
            node.attributes[ParagraphBlockKeys.textDirection],
            blockComponentTextDirectionRTL,
          );
        }
        state.undoManager.undo();
        expect(
          state.document.root.children.single.delta!.toPlainText(),
          'abcd',
        );
        expect(
          state.document.first!.attributes[ParagraphBlockKeys.textDirection],
          blockComponentTextDirectionRTL,
        );
      } finally {
        state.dispose();
      }
    },
  );
}
