import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

void main() {
  test('Backspace cannot merge text across an opaque placeholder', () async {
    final changes = <List<CollabEditorBlock>>[];
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [
        CollabEditorBlock(id: 'before', blockType: 'paragraph', text: '前文'),
        CollabEditorBlock(
          id: 'unknown',
          blockType: csesUnsupportedBlockType,
          text: '',
        ),
        CollabEditorBlock(id: 'after', blockType: 'paragraph', text: '后文'),
      ],
      onLocalBlocksChanged: changes.add,
    );
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    state.selection = Selection.single(path: [2], startOffset: 0);
    expect(isProtectedUnsupportedBlockBoundary(state), isTrue);
    expect(collabBlockBackspaceCommand.handler(state), KeyEventResult.handled);
    await Future<void>.delayed(Duration.zero);
    expect(adapter.blocks.map((b) => b.text), ['前文', '', '后文']);
    expect(changes, isEmpty);
  });

  test(
    'Backspace removes each URL-backed block and retains its paragraph',
    () async {
      for (final resourceType in const [
        csesLinkBlockType,
        ImageBlockKeys.type,
        csesVideoBlockType,
      ]) {
        final changes = <List<CollabEditorBlock>>[];
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: [
            CollabEditorBlock(
              id: 'resource-$resourceType',
              blockType: resourceType,
              text: 'https://example.com/resource',
            ),
            const CollabEditorBlock(
              id: 'paragraph-after-resource',
              blockType: ParagraphBlockKeys.type,
              text: '',
            ),
          ],
          onLocalBlocksChanged: changes.add,
        );
        addTearDown(adapter.dispose);
        adapter.editorState.selection = Selection.single(
          path: [1],
          startOffset: 0,
        );

        final handled = await deletePreviousUrlBackedBlock(adapter.editorState);

        // Deleting the resource is one normal editor transaction. The existing
        // empty paragraph shifts from path [1] to [0], remains selected and is
        // the only block published to Rust/Yrs by the adapter callback.
        expect(handled, isTrue);
        expect(adapter.editorState.document.root.children, hasLength(1));
        expect(
          adapter.editorState.document.first!.type,
          ParagraphBlockKeys.type,
        );
        expect(adapter.editorState.selection?.start.path, [0]);
        expect(changes, hasLength(1));
        expect(changes.single.single.blockType, ParagraphBlockKeys.type);
        expect(changes.single.single.id, 'paragraph-after-resource');
      }
    },
  );

  test(
    'Backspace does not remove a resource away from paragraph start',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'link',
            blockType: csesLinkBlockType,
            text: 'https://example.com',
          ),
          CollabEditorBlock(
            id: 'paragraph',
            blockType: ParagraphBlockKeys.type,
            text: 'content',
          ),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      adapter.editorState.selection = Selection.single(
        path: [1],
        startOffset: 3,
      );

      final handled = await deletePreviousUrlBackedBlock(adapter.editorState);

      expect(handled, isFalse);
      expect(adapter.editorState.document.root.children, hasLength(2));
    },
  );
}
