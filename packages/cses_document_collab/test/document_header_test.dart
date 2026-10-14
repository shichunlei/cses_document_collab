import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/controller/collab_controller.dart';
import 'package:cses_document_collab/src/editor/collab_embed_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('old documents receive a deterministic cover, title and body', () {
    const body = CollabEditorBlock(
      id: 'existing-body',
      blockType: ParagraphBlockKeys.type,
      text: '正文',
    );

    final migrated = ensureCsesDocumentHeaderBlocks(const [
      body,
    ], defaultCoverUrl: 'https://example.test/default-cover.png');

    expect(migrated.map((block) => block.blockType), [
      csesDocumentCoverBlockType,
      csesDocumentTitleBlockType,
      ParagraphBlockKeys.type,
    ]);
    expect(migrated[0].id, csesDocumentCoverBlockId);
    expect(migrated[0].text, 'https://example.test/default-cover.png');
    expect(migrated[1].id, csesDocumentTitleBlockId);
    expect(migrated[1].text, '未命名文档');
    expect(migrated[2], same(body));
    // Reapplying the migration must be idempotent so reconnects never create a
    // second header or publish a structurally unchanged Rust snapshot.
    expect(ensureCsesDocumentHeaderBlocks(migrated), migrated);
  });

  test('existing cover and title content move ahead of body unchanged', () {
    const existing = [
      CollabEditorBlock(
        id: 'body',
        blockType: ParagraphBlockKeys.type,
        text: '正文',
      ),
      CollabEditorBlock(
        id: 'title',
        blockType: csesDocumentTitleBlockType,
        text: '已有标题',
      ),
      CollabEditorBlock(
        id: 'cover',
        blockType: csesDocumentCoverBlockType,
        text: 'https://example.com/cover.jpg',
      ),
    ];

    final normalized = ensureCsesDocumentHeaderBlocks(existing);

    expect(normalized.map((block) => block.id), ['cover', 'title', 'body']);
    expect(normalized.first.text, 'https://example.com/cover.jpg');
    expect(normalized[1].text, '已有标题');
  });

  testWidgets('cover block switches from add to editable image presentation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final coverNode = Node(
      type: csesDocumentCoverBlockType,
      attributes: {csesEmbedUrlAttribute: ''},
    );
    final state = EditorState(
      document: Document(
        root: Node(type: PageBlockKeys.type, children: [coverNode]),
      ),
    );
    var editRequests = 0;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          AppFlowyEditorLocalizations.delegate,
        ],
        home: Scaffold(
          body: AppFlowyEditor(
            editorState: state,
            blockComponentBuilders: {
              ...standardBlockComponentBuilderMap,
              csesDocumentCoverBlockType: CollabEmbedBlockComponentBuilder(
                kind: CollabEmbedKind.cover,
                onEditCover: (_, _, _) => editRequests += 1,
              ),
            },
          ),
        ),
      ),
    );
    await tester.pump();

    final addCover = find.byKey(const ValueKey('collab-document-cover-add'));
    expect(addCover, findsOneWidget);
    await tester.tap(addCover);
    expect(editRequests, 1);

    final transaction = state.transaction
      ..updateNode(coverNode, {
        csesEmbedUrlAttribute: 'https://example.com/cover.jpg',
      });
    // This test verifies rendering, not undo coalescing; disabling history
    // avoids leaving AppFlowy's 50 ms history-seal timer across test teardown.
    await state.apply(
      transaction,
      options: const ApplyOptions(recordUndo: false),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('collab-document-cover-edit')),
      findsOneWidget,
    );
    expect(addCover, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
