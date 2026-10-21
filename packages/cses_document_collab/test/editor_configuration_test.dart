import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可配置能力的事务、命令、空光标与并存实例回归。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('configuration copies collections and rejects missing paragraph and invalid limits', () {
    final blocks = [EditorBlock.paragraph, EditorBlock.heading];
    final levels = {1, 3};
    final config = EditorConfiguration(blocks: blocks, headingLevels: levels);
    blocks.clear();
    levels.clear();
    expect(config.blocks.length, 2);
    expect(config.headingLevels, {1, 3});
    expect(() => config.blocks.clear(), throwsUnsupportedError);
    expect(() => EditorConfiguration(blocks: [EditorBlock.heading]), throwsArgumentError);
    expect(() => EditorConfiguration(headingLevels: {10}), throwsArgumentError);
    expect(() => EditorConfiguration(maxBlocks: 0), throwsArgumentError);
    expect(() => LocalEditorController(configuration: EditorConfiguration.document), throwsArgumentError);
  });
  test('two configurations enforce blocks, nonconsecutive headings and undo independently', () async {
    final first = LocalEditorController(
      initialText: 'Title',
      configuration: EditorConfiguration(blocks: [EditorBlock.paragraph, EditorBlock.heading], headingLevels: {1, 3}),
    );
    final second = LocalEditorController(
      initialText: 'Other',
      configuration: EditorConfiguration(blocks: [EditorBlock.paragraph, EditorBlock.quote]),
    );
    try {
      final state = first.editorState;
      state.selection = Selection.collapsed(Position(path: [0]));
      await first.convert('heading', level: 2);
      expect(state.document.root.children.single.type, 'paragraph');
      expect(await applyBlockShortcut(state, state.selection!, 'quote'), isFalse);
      await first.convert('heading', level: 3);
      expect(state.document.root.children.single.attributes['level'], 3);
      state.undoManager.undo();
      expect(state.document.root.children.single.type, 'paragraph');
      state.undoManager.redo();
      expect(state.document.root.children.single.type, 'heading');
      expect(second.editorState.document.root.children.single.type, 'paragraph');
      expect(CollabBlockLocks.of(state), isNull);
      final revision = first.revision;
      await state.apply(state.transaction..insertNode([1], quoteNode(delta: Delta()..insert('rejected'))));
      expect(first.revision, revision);
      expect(state.document.root.children.length, 1);
    } finally {
      await first.close();
      await second.close();
    }
  });
  test('disabled formats cannot enter by commands, defaults, delta or locks', () async {
    final local = LocalEditorController(
      initialText: 'Text',
      configuration: EditorConfiguration(
        blocks: [EditorBlock.paragraph],
        inlineFormats: {EditorInlineFormat.bold},
        alignments: {'left'},
      ),
    );
    try {
      final state = local.editorState;
      state.selection = Selection.collapsed(Position(path: [0]));
      await local.format({'t:px': 24});
      expect(state.toggledStyle['t:px'], isNull);
      await local.format({AppFlowyRichTextKeys.bold: true});
      expect(state.toggledStyle[AppFlowyRichTextKeys.bold], isTrue);
      state.selection = Selection.single(path: [0], startOffset: 0, endOffset: 4);
      final revision = local.revision;
      await state.apply(
        state.transaction..formatText(state.document.root.children.single, 0, 4, {AppFlowyRichTextKeys.italic: true}),
      );
      expect(local.revision, revision);
      final node = state.document.root.children.single;
      await state.apply(
        state.transaction
          ..updateNode(node, {paragraphPropertyAttribute('textDefaults'): '{"value":{"a:italic":true}}'}),
      );
      expect(local.revision, revision);
      await state.apply(state.transaction..updateNode(node, {'cses_block_lock': true}));
      expect(local.revision, revision);
      expect(node.attributes['cses_block_lock'], isNull);
      await expectLater(local.layout(alignment: 'center'), throwsArgumentError);
    } finally {
      await local.close();
    }
  });
  test('configured character and block limits reject paste atomically', () async {
    final local = LocalEditorController(
      initialText: '123',
      configuration: EditorConfiguration(maxCharacters: 5, maxBlocks: 2),
    );
    try {
      final state = local.editorState;
      state.selection = Selection.collapsed(Position(path: [0], offset: 3));
      await expectLater(local.pasteText('456'), throwsStateError);
      expect(state.document.root.children.single.delta!.toPlainText(), '123');
      await local.pasteText('4\n5');
      expect(state.document.root.children.length, 2);
      expect(state.document.root.children.last.delta!.toPlainText(), '5');
      state.undoManager.undo();
      expect(state.document.root.children.single.delta!.toPlainText(), '123');
    } finally {
      await local.close();
    }
  });
}
