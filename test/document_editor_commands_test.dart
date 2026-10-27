import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证公开编辑命令的宿主容器支持、能力限制和撤销边界。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'public paragraph command splits within a host container and restores text on undo',
    () async {
      final document = DocumentEditorController(
        document: Document(
          root: Node(
            type: PageBlockKeys.type,
            children: [
              Node(
                type: 'host-content-section',
                children: [
                  paragraphNode(
                    delta: Delta()
                      ..insert(
                        '甲乙',
                        attributes: {AppFlowyRichTextKeys.bold: true},
                      ),
                  ),
                ],
              ),
            ],
          ),
        ),
        commandContext: const EditorCommandContext(localOnly: true),
      );
      final state = document.editorState;
      try {
        state.selection = Selection.collapsed(
          Position(path: [0, 0], offset: 1),
        );
        expect(await handleDocumentParagraphEnter(state), isTrue);
        final section = state.document.root.children.single;
        expect(section.type, 'host-content-section');
        expect(section.children.map((node) => node.delta!.toPlainText()), [
          '甲',
          '乙',
        ]);
        expect(section.children.last.delta!.toJson(), [
          {
            'insert': '乙',
            'attributes': {AppFlowyRichTextKeys.bold: true},
          },
        ]);
        state.undoManager.undo();
        expect(section.children.single.delta!.toPlainText(), '甲乙');
        state.editable = false;
        expect(await handleDocumentParagraphEnter(state), isFalse);
      } finally {
        await document.close();
      }
      expect(await handleDocumentParagraphEnter(state), isFalse);
    },
  );

  test(
    'public block command respects capability selection and preserves undo',
    () async {
      final document = DocumentEditorController(
        commandContext: EditorCommandContext(
          configuration: EditorConfiguration(
            blocks: const [EditorBlock.paragraph, EditorBlock.todoList],
          ),
          localOnly: true,
        ),
      );
      final state = document.editorState;
      final selection = Selection.collapsed(Position(path: [0]));
      try {
        expect(
          await applyDocumentBlockShortcut(
            state,
            selection,
            TodoListBlockKeys.type,
          ),
          isTrue,
        );
        expect(
          state.document.root.children.single.type,
          TodoListBlockKeys.type,
        );
        state.undoManager.undo();
        expect(
          state.document.root.children.single.type,
          ParagraphBlockKeys.type,
        );
        expect(
          await applyDocumentBlockShortcut(
            state,
            selection,
            HeadingBlockKeys.type,
            headingLevel: 1,
          ),
          isFalse,
        );
        expect(
          state.document.root.children.single.type,
          ParagraphBlockKeys.type,
        );
      } finally {
        await document.close();
      }
    },
  );
}
