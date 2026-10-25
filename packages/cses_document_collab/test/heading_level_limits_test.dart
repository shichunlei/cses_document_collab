import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_editing.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证六级标题在配置、命令、事务、远端投影与JSON交换之间保持一致。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'default and document configurations enable exactly six heading levels',
    () {
      for (final config in [
        EditorConfiguration(),
        EditorConfiguration.document,
      ]) {
        expect(config.headingLevels, {1, 2, 3, 4, 5, 6});
        for (final level in [0, 7, 8, 9, 10]) {
          expect(config.allowsBlock('heading', level: level), isFalse);
          expect(
            () => EditorConfiguration(headingLevels: {1, level}),
            throwsArgumentError,
          );
        }
      }
    },
  );

  test(
    'unsupported heading commands and direct transactions leave content and history intact',
    () async {
      final editor = LocalEditorController(initialText: 'Title');
      addTearDown(editor.close);
      final state = editor.editorState;
      state.selection = Selection.single(path: [0], startOffset: 2);
      await editor.convert('heading', level: 6);
      final before = state.document.toJson();
      final undoEntry = state.undoManager.undoStack.last;
      for (final level in [7, 8, 9]) {
        await editor.convert('heading', level: level);
        await applyEditorBlockStyle(state, 'heading', headingLevel: level);
        await state.apply(
          state.transaction..updateNode(state.document.first!, {
            HeadingBlockKeys.level: level,
          }),
        );
        expect(state.document.toJson(), before);
        expect(state.undoManager.undoStack.last, same(undoEntry));
      }
      state.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(state.document.first!.type, 'paragraph');
      state.undoManager.redo();
      await Future<void>.delayed(Duration.zero);
      expect(state.document.first!.attributes[HeadingBlockKeys.level], 6);
    },
  );

  for (final level in [7, 8, 9]) {
    for (final nextStyle in ['same', 'body']) {
      for (final offset in [0, 1, 2]) {
        test(
          'legacy level $level Enter at $offset with $nextStyle normalizes only the new node',
          () async {
            final adapter = AppFlowyBlockEditorAdapter(
              initialBlocks: [
                CollabEditorBlock(
                  id: 'legacy',
                  blockType: 'heading_$level',
                  text: 'AB',
                  paragraphStyle: CollabResource.fromValues({
                    'heading': level,
                    'nextParagraphStyle': nextStyle,
                  }),
                ),
              ],
              onLocalBlocksChanged: (_) {},
            );
            addTearDown(adapter.dispose);
            final state = adapter.editorState;
            state.selection = Selection.single(path: [0], startOffset: offset);
            expect(await handleCollabParagraphEnter(state), isTrue);
            final blocks = adapter.blocks;
            expect(blocks, hasLength(2));
            expect(blocks.map((b) => b.text).join(), 'AB');
            final original = blocks.firstWhere((b) => b.id == 'legacy');
            final created = blocks.singleWhere((b) => b.id != 'legacy');
            expect(original.paragraphStyle!.values['heading'], level);
            final body = offset == 2 && nextStyle == 'body';
            expect(created.blockType, body ? 'paragraph' : 'heading_6');
            expect(
              created.paragraphStyle!.values['heading'],
              body ? isNull : 6,
            );
          },
        );
      }
    }
    test(
      'remote legacy level $level displays H6 without echo or changing its source',
      () {
        final source = CollabEditorBlock(
          id: 'title',
          blockType: 'heading_$level',
          text: 'Legacy title',
        );
        final changes = <List<CollabEditorBlock>>[];
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: [source],
          onLocalBlocksChanged: changes.add,
        );
        addTearDown(adapter.dispose);
        expect(
          adapter.editorState.document.first!.attributes[HeadingBlockKeys
              .level],
          6,
        );
        expect(adapter.blocks.single.blockType, 'heading_6');
        expect(source.blockType, 'heading_$level');
        expect(changes, isEmpty);
      },
    );

    test(
      'desktop JSON level $level imports and exports H6 while preserving text and unrelated props',
      () {
        final source = <String, dynamic>{
          'id': 'title',
          'flavour': 'paragraph',
          'nodeType': 'editable',
          'props': {'heading': level, 'custom': 'keep'},
          'meta': {'author': 'user'},
          'children': [
            {'insert': 'Legacy title'},
          ],
        };
        final node = BlockCraftJsonCodec.decodeBlock(source);
        expect(node.attributes[HeadingBlockKeys.level], 6);
        final result = BlockCraftJsonCodec.encodeBlock(node);
        expect(result['props'], {'heading': 6, 'custom': 'keep'});
        expect(result['meta'], {'author': 'user'});
        expect(result['children'], [
          {'insert': 'Legacy title'},
        ]);
        expect((source['props'] as Map)['heading'], level);
      },
    );
  }
}
