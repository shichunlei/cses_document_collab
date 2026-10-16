import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_link_view.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter_test/flutter_test.dart';

/// Canonicalizes borrowed [block] as a native acknowledgement, clearing edit intent.
CollabEditorBlock _ack(CollabEditorBlock block) => CollabEditorBlock(
  id: block.id,
  blockType: block.blockType,
  text: block.text,
  segments: block.segments,
  parentId: block.parentId,
  resource: block.resource == null
      ? null
      : CollabResource(properties: block.resource!.properties),
);

/// Creates a fixture adapter for [kind]/[url], with an unaffected adjacent paragraph.
AppFlowyBlockEditorAdapter _adapter(String kind, String url) =>
    AppFlowyBlockEditorAdapter(
      initialBlocks: [
        CollabEditorBlock(
          id: 'link',
          blockType: kind,
          text: url,
          resource: CollabResource.fromValues(
            kind == 'bookmark' ? {'title': '标题'} : {'wr': 75, 'ar': 1.5},
          ),
        ),
        const CollabEditorBlock(
          id: 'body',
          blockType: 'paragraph',
          text: '相邻正文',
        ),
      ],
      onLocalBlocksChanged: (_) {},
    );

/// Registers desktop representation, identity/history and conflict boundaries.
void main() {
  for (final kind in ['bookmark', 'embed', 'figma-embed', 'juejin-embed']) {
    test(
      '$kind performs all six directions with native acknowledgements and undo/redo',
      () async {
        final url = switch (kind) {
          'figma-embed' => 'https://www.figma.com/design/demo/Design',
          'juejin-embed' => 'https://juejin.cn/post/123',
          _ => 'https://example.test/article',
        };
        final adapter = _adapter(kind, url);
        addTearDown(adapter.dispose);
        final state = adapter.editorState;
        final sequence = kind == 'bookmark'
            ? [
                CollabLinkView.inline,
                CollabLinkView.card,
                CollabLinkView.embed,
                CollabLinkView.inline,
                CollabLinkView.embed,
                CollabLinkView.card,
              ]
            : [
                CollabLinkView.inline,
                CollabLinkView.embed,
                CollabLinkView.card,
                CollabLinkView.inline,
                CollabLinkView.card,
                CollabLinkView.embed,
              ];
        for (final view in sequence) {
          final previous = adapter.blocks.first;
          expect(
            await changeCollabLinkView(state, state.document.first!, view),
            isTrue,
          );
          final changed = adapter.blocks.first;
          expect(changed.id, isNot(previous.id));
          expect(changed.replacesId, previous.id);
          expect(changed.text, url);
          expect(adapter.blocks.last.text, '相邻正文');
          expect(collabLinkView(state.document.first!), view);
          if (view == CollabLinkView.inline) {
            expect(changed.blockType, 'paragraph');
            expect(changed.segments.single.href, url);
            expect(changed.resource, isNull);
          } else {
            expect(
              changed.blockType,
              view == CollabLinkView.card ? 'bookmark' : 'embed',
            );
            expect(state.document.first!.delta, isNull);
          }
          await adapter.replaceFromRemote(adapter.blocks.map(_ack).toList());
          state.undoManager.undo();
          await Future<void>.delayed(Duration.zero);
          expect(adapter.blocks.first.blockType, previous.blockType);
          expect(adapter.blocks.first.text, previous.text);
          await adapter.replaceFromRemote(adapter.blocks.map(_ack).toList());
          state.undoManager.redo();
          await Future<void>.delayed(Duration.zero);
          expect(collabLinkView(state.document.first!), view);
          expect(adapter.blocks.first.text, url);
          await adapter.replaceFromRemote(adapter.blocks.map(_ack).toList());
        }
      },
    );
  }

  test(
    'undo follows remote reorder and does not overwrite a newer URL',
    () async {
      final adapter = _adapter('bookmark', 'https://example.test/a');
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      await changeCollabLinkView(
        state,
        state.document.first!,
        CollabLinkView.embed,
      );
      final converted = _ack(adapter.blocks.first);
      await adapter.replaceFromRemote([adapter.blocks.last, converted]);
      state.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(adapter.blocks.first.text, '相邻正文');
      expect(adapter.blocks.last.blockType, 'bookmark');
      await adapter.replaceFromRemote(adapter.blocks.map(_ack).toList());
      await changeCollabLinkView(
        state,
        state.document.last!,
        CollabLinkView.embed,
      );
      final latest = adapter.blocks.last;
      await adapter.replaceFromRemote([
        adapter.blocks.first,
        CollabEditorBlock(
          id: latest.id,
          blockType: latest.blockType,
          text: 'https://example.test/remote',
          resource: latest.resource,
        ),
      ]);
      state.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(adapter.blocks.last.text, 'https://example.test/remote');
      expect(adapter.blocks.last.blockType, 'embed');
    },
  );

  test(
    'readonly, detached, mixed text and stale panel snapshots cannot convert',
    () async {
      final adapter = _adapter('bookmark', 'https://example.test/a');
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      final source = state.document.first!;
      final fingerprint = collabLinkFingerprint(source);
      state.editable = false;
      expect(
        await changeCollabLinkView(state, source, CollabLinkView.embed),
        isFalse,
      );
      state.editable = true;
      expect(
        await changeCollabLinkView(
          state,
          source.copyWith(),
          CollabLinkView.embed,
        ),
        isFalse,
      );
      await changeCollabResourceProperty(
        state,
        'link',
        'url',
        'https://example.test/b',
      );
      expect(
        await changeCollabLinkView(
          state,
          source,
          CollabLinkView.embed,
          fingerprint: fingerprint,
        ),
        isFalse,
      );
      final mixed = paragraphNode(
        delta: Delta()
          ..insert('正文 ')
          ..insert(
            '链接',
            attributes: {AppFlowyRichTextKeys.href: 'https://example.test'},
          ),
      );
      expect(collabLinkUrl(mixed), isNull);
      final styled = paragraphNode(
        delta: Delta()
          ..insert(
            '链接',
            attributes: {
              AppFlowyRichTextKeys.href: 'https://example.test',
              'bold': true,
            },
          )
          ..insert(
            '名称',
            attributes: {AppFlowyRichTextKeys.href: 'https://example.test'},
          ),
      );
      expect(collabLinkUrl(styled), 'https://example.test');
    },
  );
}
