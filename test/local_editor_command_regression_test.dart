import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_table.dart';
import 'package:flutter_test/flutter_test.dart';

/// 本地编辑命令对容器、代码粘贴及实例能力的边界回归。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('disabled alignment must not disable heading conversion', () async {
    final local = LocalEditorController(
      configuration: EditorConfiguration(alignments: const []),
    );
    try {
      final state = local.editorState;
      state.selection = Selection.collapsed(Position(path: [0]));
      await applyBlockShortcut(
        state,
        state.selection!,
        'heading',
        headingLevel: 2,
      );
      expect(state.document.first!.type, 'heading');
      await state.apply(
        state.transaction
          ..updateNode(state.document.first!, {blockComponentAlign: 'center'}),
      );
      expect(state.document.first!.attributes[blockComponentAlign], 'left');
      await expectLater(local.layout(alignment: 'center'), throwsArgumentError);
    } finally {
      await local.close();
    }
  });

  test(
    'pasting multiline text in code must preserve a single code block',
    () async {
      final local = LocalEditorController();
      try {
        final state = local.editorState;
        state.selection = Selection.collapsed(Position(path: [0]));
        await applyBlockShortcut(state, state.selection!, 'code');
        await local.pasteText('one\ntwo');
        expect(state.document.root.children, hasLength(1));
        expect(state.document.first!.type, 'code');
        expect(state.document.first!.delta!.toPlainText(), 'one\ntwo');
      } finally {
        await local.close();
      }
    },
  );

  for (final reverse in [false, true]) {
    test(
      'code paste preserves identity, suffix, metadata and history; reverse=$reverse',
      () async {
        final local = LocalEditorController(
          initialText: 'abcd',
          configuration: EditorConfiguration(maxBlocks: 1),
        );
        try {
          final state = local.editorState;
          state.selection = Selection.collapsed(Position(path: [0]));
          await local.convert('code');
          final node = state.document.first!;
          await state.apply(
            state.transaction
              ..updateNode(node, {'language': 'Dart', 'name': 'demo'}),
          );
          final attributes = Map<String, dynamic>.from(node.attributes)
            ..remove(blockComponentDelta);
          state.selection = Selection.single(
            path: [0],
            startOffset: reverse ? 3 : 1,
            endOffset: reverse ? 1 : 3,
          );
          await local.pasteText('X\r\nY\n');
          expect(state.document.first, same(node));
          expect(node.delta!.toPlainText(), 'aX\nY\nd');
          expect(
            Map<String, dynamic>.from(node.attributes)
              ..remove(blockComponentDelta),
            attributes,
          );
          expect(
            state.selection,
            Selection.collapsed(Position(path: [0], offset: 5)),
          );
          state.undoManager.undo();
          expect(node.delta!.toPlainText(), 'abcd');
          state.undoManager.redo();
          expect(node.delta!.toPlainText(), 'aX\nY\nd');
        } finally {
          await local.close();
        }
      },
    );
  }

  test(
    'code paste rejects capacity before mutation and ignores readonly input',
    () async {
      final local = LocalEditorController(
        initialText: 'abc',
        configuration: EditorConfiguration(maxCharacters: 4),
      );
      try {
        final state = local.editorState;
        state.selection = Selection.collapsed(Position(path: [0], offset: 3));
        await local.convert('code');
        final before = state.document.toJson();
        final revision = local.revision;
        await expectLater(local.pasteText('XY'), throwsStateError);
        expect(state.document.toJson(), before);
        expect(local.revision, revision);
        state.editable = false;
        await local.pasteText('X');
        expect(state.document.toJson(), before);
      } finally {
        await local.close();
      }
    },
  );

  test('converting a container must not discard its child content', () async {
    final local = LocalEditorController(initialText: 'Anchor');
    try {
      final state = local.editorState;
      final cell = await insertCollabTable(
        state,
        Selection.collapsed(Position(path: [0])),
      );
      state.selection = cell;
      final leaf = state.getNodeAtPath(cell!.start.path)!;
      await state.apply(state.transaction..insertText(leaf, 0, 'KEEP'));
      final table = state.document.root.children.firstWhere(
        (node) => node.type == 'table',
      );
      state.selection = Selection.collapsed(Position(path: table.path));
      final before = state.document.toJson();
      final revision = local.revision;
      final history = state.undoManager.undoStack.last;
      final selection = state.selection;
      await local.convert('paragraph');
      expect(state.document.toJson(), before);
      expect(state.selection, selection);
      expect(local.revision, revision);
      expect(state.undoManager.undoStack.last, same(history));
    } finally {
      await local.close();
    }
  });

  for (final containerType in ['callout', 'paragraph']) {
    test(
      'conversion preserves $containerType descendants and mixed ranges',
      () async {
        final local = LocalEditorController(initialText: 'before');
        try {
          final state = local.editorState;
          await state.apply(
            state.transaction..insertNode(
              [1],
              Node(
                type: containerType,
                children: [paragraphNode(text: 'nested')],
                attributes: containerType == 'paragraph'
                    ? {'delta': (Delta()..insert('parent')).toJson()}
                    : {},
              ),
            ),
          );
          state.selection = Selection(
            start: Position(path: [0]),
            end: Position(path: [1]),
          );
          final before = state.document.toJson();
          final revision = local.revision;
          await local.convert('heading', level: 2);
          expect(state.document.toJson(), before);
          expect(local.revision, revision);

          state.selection = Selection.collapsed(Position(path: [1, 0]));
          await local.convert('heading', level: 2);
          expect(state.getNodeAtPath([1, 0])!.type, 'heading');
          expect(state.getNodeAtPath([1, 0])!.delta!.toPlainText(), 'nested');
          state.undoManager.undo();
          expect(state.document.toJson(), before);
        } finally {
          await local.close();
        }
      },
    );
  }

  test('conversion cannot synthesize structural blocks from text', () async {
    final local = LocalEditorController(initialText: 'keep');
    try {
      final state = local.editorState;
      state.selection = Selection.collapsed(Position(path: [0]));
      final before = state.document.toJson();
      for (final type in ['table', 'callout', 'image', 'mermaid']) {
        await local.convert(type);
        expect(state.document.toJson(), before);
      }
      expect(state.undoManager.undoStack.isEmpty, isTrue);
    } finally {
      await local.close();
    }
  });
}
