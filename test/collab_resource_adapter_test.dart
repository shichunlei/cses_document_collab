import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:flutter_test/flutter_test.dart';

String _url(String kind) => switch (kind) {
  'figma-embed' => 'https://www.figma.com/design/demo/Design',
  'juejin-embed' => 'https://juejin.cn/post/123',
  _ => 'https://example.test/resource',
};

void main() {
  for (final kind in collabResourceTypes) {
    test(
      '$kind inserts as a selectable resource and retains metadata through body edits',
      () async {
        final changes = <List<CollabEditorBlock>>[];
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: const [
            CollabEditorBlock(id: 'p', blockType: 'paragraph', text: '正文'),
          ],
          onLocalBlocksChanged: changes.add,
        );
        addTearDown(adapter.dispose);
        final state = adapter.editorState;
        final selection = await applyUrlBlockShortcut(
          state,
          Selection.single(path: [0], startOffset: 2),
          kind,
          _url(kind),
        );
        expect(selection, isNotNull);
        final inserted = adapter.blocks[1];
        expect(inserted.blockType, kind);
        expect(inserted.text, _url(kind));
        expect(inserted.resource, isNotNull);
        expect(state.document.nodeAtPath([1])!.delta, isNull);
        expect(state.document.last!.delta, isNotNull);
        await state.apply(
          state.transaction..insertText(state.document.first!, 2, '修改'),
        );
        expect(adapter.blocks[1].resource!.propertyEdits, isNull);
        expect(
          adapter.blocks[1].resource!.properties,
          inserted.resource!.properties,
        );
      },
    );
  }

  test(
    'resource field undo follows identity and preserves newer remote fields',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          CollabEditorBlock(
            id: 'file',
            blockType: 'attachment',
            text: 'https://example.test/a.pdf',
            resource: CollabResource.fromValues({
              'name': '原名.pdf',
              'size': 100,
            }),
          ),
          const CollabEditorBlock(id: 'p', blockType: 'paragraph', text: '正文'),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [1], startOffset: 1);
      await changeCollabResourceProperty(state, 'file', 'name', '新名.pdf');
      expect(jsonDecode(changes.last.first.resource!.propertyEdits!), {
        'name': {'value': '新名.pdf'},
      });
      await adapter.replaceFromRemote([
        const CollabEditorBlock(id: 'p', blockType: 'paragraph', text: '远端正文'),
        CollabEditorBlock(
          id: 'file',
          blockType: 'attachment',
          text: 'https://example.test/a.pdf',
          resource: CollabResource.fromValues({'name': '新名.pdf', 'size': 900}),
        ),
      ]);
      state.selection = Selection.single(path: [0], startOffset: 2);
      state.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      final file = adapter.blocks.last;
      expect(file.id, 'file');
      expect(file.resource!.string('name'), '原名.pdf');
      expect(file.resource!.number('size'), 900);
      expect(state.selection!.start.path, [0]);
      expect(state.selection!.start.offset, 2);
      await changeCollabResourceProperty(
        state,
        'file',
        'url',
        'https://example.test/new.pdf',
      );
      expect(adapter.blocks.last.text, 'https://example.test/new.pdf');
      expect(jsonDecode(changes.last.last.resource!.propertyEdits!), {
        'url': {'value': 'https://example.test/new.pdf'},
      });
      expect(
        await changeCollabResourceProperty(
          state,
          'file',
          'url',
          'javascript:bad',
        ),
        isFalse,
      );
      state.editable = false;
      expect(
        await changeCollabResourceProperty(state, 'file', 'name', '禁止'),
        isFalse,
      );
    },
  );
}
