import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:cses_mobile_collab_demo/src/ui/editor_shortcut_toolbar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'list conversion and undo publish distinct replacement identities',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(id: 'p', blockType: 'paragraph', text: 'first'),
          CollabEditorBlock(id: 'tail', blockType: 'paragraph', text: 'tail'),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      await state.formatNode(
        Selection.single(path: [0], startOffset: 0),
        (node) => node.copyWith(type: NumberedListBlockKeys.type),
      );
      final converted = changes.single.first;
      expect(converted.id, isNot('p'));
      expect(converted.replacesId, 'p');
      state.undoManager.undo();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(changes.last.length, 2);
      expect(changes.last.first.blockType, 'paragraph');
      expect(changes.last.first.id, isNot(converted.id));
      expect(changes.last.first.replacesId, converted.id);
    },
  );

  const initial = CollabEditorBlock(
    id: 'paragraph-a',
    blockType: 'paragraph',
    text: 'Hello',
  );

  test(
    'list conversion recovers source when the formatter drops custom attributes',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [initial],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      await adapter.editorState.formatNode(
        Selection.single(path: [0], startOffset: 0),
        (node) => node.copyWith(
          type: NumberedListBlockKeys.type,
          attributes: {NumberedListBlockKeys.delta: node.delta!.toJson()},
        ),
      );
      expect(changes.single.single.replacesId, initial.id);
      expect(changes.single.single.id, isNot(initial.id));
    },
  );

  test('publishes a local block transaction once with a stable id', () async {
    final changes = <List<CollabEditorBlock>>[];
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [initial],
      onLocalBlocksChanged: changes.add,
    );
    addTearDown(adapter.dispose);

    final node = adapter.editorState.document.first!;
    final transaction = adapter.editorState.transaction
      ..insertText(node, 5, ' 😀');
    await adapter.editorState.apply(transaction);

    expect(adapter.text, 'Hello 😀');
    expect(changes, [
      const [
        CollabEditorBlock(
          id: 'paragraph-a',
          blockType: 'paragraph',
          text: 'Hello 😀',
        ),
      ],
    ]);
  });

  test('remote block text patches do not echo as local transactions', () async {
    final changes = <List<CollabEditorBlock>>[];
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [
        CollabEditorBlock(
          id: 'paragraph-a',
          blockType: 'paragraph',
          text: 'before',
        ),
      ],
      onLocalBlocksChanged: changes.add,
    );
    addTearDown(adapter.dispose);
    final originalNode = adapter.editorState.document.first;

    await adapter.replaceFromRemote(const [
      CollabEditorBlock(
        id: 'paragraph-a',
        blockType: 'paragraph',
        text: 'after',
      ),
    ]);

    expect(adapter.text, 'after');
    expect(adapter.editorState.document.first, same(originalNode));
    expect(changes, isEmpty);
  });

  test(
    'maps heading, list, quote and code nodes to supported block types',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [initial],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);

      await adapter.replaceFromRemote(const [
        CollabEditorBlock(id: 'title', blockType: 'heading_2', text: 'Title'),
        CollabEditorBlock(
          id: 'bullet',
          blockType: 'bulleted_list',
          text: 'Bullet',
        ),
        CollabEditorBlock(
          id: 'number',
          blockType: 'numbered_list',
          text: 'Number',
        ),
        CollabEditorBlock(id: 'quote', blockType: 'quote', text: 'Quote'),
        CollabEditorBlock(id: 'code', blockType: 'code', text: 'let x = 1;'),
      ]);
      final nodes = adapter.editorState.document.root.children;
      expect(nodes.map((node) => node.type), [
        HeadingBlockKeys.type,
        BulletedListBlockKeys.type,
        NumberedListBlockKeys.type,
        QuoteBlockKeys.type,
        csesCodeBlockType,
      ]);
      expect(nodes.first.attributes[HeadingBlockKeys.level], 2);
      expect(adapter.blocks.map((block) => block.blockType), [
        'heading_2',
        'bulleted_list',
        'numbered_list',
        'quote',
        'code',
      ]);
      expect(changes, isEmpty);
    },
  );

  test('round-trips collaborative link, image and video URLs', () async {
    final changes = <List<CollabEditorBlock>>[];
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [initial],
      onLocalBlocksChanged: changes.add,
    );
    addTearDown(adapter.dispose);
    const expected = [
      CollabEditorBlock(
        id: 'link-a',
        blockType: csesLinkBlockType,
        text: 'https://example.com/article',
      ),
      CollabEditorBlock(
        id: 'image-a',
        blockType: ImageBlockKeys.type,
        text: 'https://example.com/photo.jpg',
        alignment: 'center',
      ),
      CollabEditorBlock(
        id: 'video-a',
        blockType: csesVideoBlockType,
        text: 'https://example.com/movie.mp4',
      ),
    ];

    await adapter.replaceFromRemote(expected);

    // URL-backed AppFlowy nodes must not gain an editable Delta: the renderer
    // reads the URL attribute while the adapter exposes it as CollabBlock.text.
    final nodes = adapter.editorState.document.root.children;
    expect(nodes.map((node) => node.type), ['link', 'image', 'video']);
    expect(nodes.every((node) => node.delta == null), isTrue);
    expect(nodes[0].attributes[csesEmbedUrlAttribute], expected[0].text);
    expect(nodes[1].attributes[ImageBlockKeys.url], expected[1].text);
    expect(nodes[2].attributes[csesEmbedUrlAttribute], expected[2].text);
    expect(adapter.blocks, expected);
    expect(changes, isEmpty);
  });

  test('round-trips the fixed document cover and editable title', () async {
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [initial],
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);
    const expected = [
      CollabEditorBlock(
        id: csesDocumentCoverBlockId,
        blockType: csesDocumentCoverBlockType,
        text: 'https://example.com/cover.jpg',
      ),
      CollabEditorBlock(
        id: csesDocumentTitleBlockId,
        blockType: csesDocumentTitleBlockType,
        text: '文档标题',
      ),
      initial,
    ];

    await adapter.replaceFromRemote(expected);

    final nodes = adapter.editorState.document.root.children;
    expect(nodes.map((node) => node.type), [
      csesDocumentCoverBlockType,
      csesDocumentTitleBlockType,
      ParagraphBlockKeys.type,
    ]);
    expect(nodes.first.delta, isNull);
    expect(
      nodes.first.attributes[csesEmbedUrlAttribute],
      'https://example.com/cover.jpg',
    );
    expect(nodes[1].delta?.toPlainText(), '文档标题');
    expect(adapter.blocks, expected);
  });

  test(
    'publishes local cover and title edits in one header snapshot',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: csesDocumentCoverBlockId,
            blockType: csesDocumentCoverBlockType,
            text: csesDefaultDocumentCoverUrl,
          ),
          CollabEditorBlock(
            id: csesDocumentTitleBlockId,
            blockType: csesDocumentTitleBlockType,
            text: '标题',
          ),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      final nodes = adapter.editorState.document.root.children;
      final transaction = adapter.editorState.transaction
        ..updateNode(nodes[0], {
          csesEmbedUrlAttribute: 'https://example.com/new-cover.jpg',
        })
        ..insertText(nodes[1], 2, '已修改');

      await adapter.editorState.apply(transaction);

      // Header data follows the ordinary adapter transaction path, guaranteeing
      // that CollabController receives both edits for one Rust/Yrs snapshot.
      expect(changes, hasLength(1));
      expect(changes.single[0].blockType, csesDocumentCoverBlockType);
      expect(changes.single[0].text, 'https://example.com/new-cover.jpg');
      expect(changes.single[1].blockType, csesDocumentTitleBlockType);
      expect(changes.single[1].text, '标题已修改');
    },
  );

  test(
    'publishes an inserted link and its trailing paragraph locally',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'paragraph-a',
            blockType: ParagraphBlockKeys.type,
            text: 'before',
          ),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);

      final nextSelection = await applyUrlBlockShortcut(
        adapter.editorState,
        Selection.single(path: [0], startOffset: 6),
        csesLinkBlockType,
        'https://example.com/article',
      );

      // This exercises the actual local transaction callback consumed by
      // CollabController, not only remote reconstruction. One snapshot must
      // contain the source paragraph, URL block and editable trailing paragraph.
      expect(nextSelection?.start.path, [2]);
      expect(changes, hasLength(1));
      expect(changes.single.map((block) => block.blockType), [
        ParagraphBlockKeys.type,
        csesLinkBlockType,
        ParagraphBlockKeys.type,
      ]);
      expect(changes.single[1].text, 'https://example.com/article');
    },
  );

  test('round-trips H9, block layout and script attributes', () async {
    final changes = <List<CollabEditorBlock>>[];
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [
        CollabEditorBlock(id: 'list', blockType: 'numbered_list', text: 'x2'),
      ],
      onLocalBlocksChanged: changes.add,
    );
    addTearDown(adapter.dispose);

    await adapter.replaceFromRemote(const [
      CollabEditorBlock(
        id: 'heading',
        blockType: 'heading_9',
        text: 'x2',
        alignment: 'center',
        segments: [
          CollabEditorTextSegment(text: 'x'),
          CollabEditorTextSegment(text: '2', superscript: true),
        ],
      ),
      CollabEditorBlock(
        id: 'list',
        blockType: 'numbered_list',
        text: 'nested',
        alignment: 'right',
        indent: 2,
      ),
    ]);

    final nodes = adapter.editorState.document.root.children;
    expect(nodes.first.attributes[HeadingBlockKeys.level], 9);
    expect(nodes.first.attributes[blockComponentAlign], 'center');
    expect(
      nodes.first.delta!.last.attributes?[csesSuperscriptAttribute],
      isTrue,
    );
    expect(nodes.last.attributes[blockComponentAlign], 'right');
    expect(nodes.last.attributes[csesBlockIndentAttribute], 2);
    expect(adapter.blocks.first.blockType, 'heading_9');
    expect(adapter.blocks.first.segments.last.superscript, isTrue);
    expect(adapter.blocks.last.indent, 2);
    expect(changes, isEmpty);
  });

  test('remote list layout patches the existing node without echo', () async {
    final changes = <List<CollabEditorBlock>>[];
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [
        CollabEditorBlock(id: 'list', blockType: 'bulleted_list', text: 'item'),
      ],
      onLocalBlocksChanged: changes.add,
    );
    addTearDown(adapter.dispose);
    final original = adapter.editorState.document.first!;

    await adapter.replaceFromRemote(const [
      CollabEditorBlock(
        id: 'list',
        blockType: 'bulleted_list',
        text: 'item',
        alignment: 'right',
        indent: 3,
      ),
    ]);

    expect(adapter.editorState.document.first, same(original));
    expect(original.attributes[blockComponentAlign], 'right');
    expect(original.attributes[csesBlockIndentAttribute], 3);
    expect(changes, isEmpty);
  });

  test('new nodes with copied ids are assigned unique block ids', () async {
    final changes = <List<CollabEditorBlock>>[];
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [initial],
      onLocalBlocksChanged: changes.add,
    );
    addTearDown(adapter.dispose);
    final first = adapter.editorState.document.first!;
    final copied = first.copyWith(
      attributes: {
        ...first.attributes,
        ParagraphBlockKeys.delta: (Delta()..insert('second')).toJson(),
      },
    );

    final transaction = adapter.editorState.transaction
      ..insertNode([1], copied);
    await adapter.editorState.apply(transaction);

    expect(changes, hasLength(1));
    expect(changes.single, hasLength(2));
    expect(changes.single.map((block) => block.id).toSet(), hasLength(2));
    expect(changes.single.last.text, 'second');
  });

  test('block type conversion keeps the collaborative block id', () async {
    final changes = <List<CollabEditorBlock>>[];
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [initial],
      onLocalBlocksChanged: changes.add,
    );
    addTearDown(adapter.dispose);

    await adapter.editorState.formatNode(
      Selection.single(path: [0], startOffset: 0),
      (node) => node.copyWith(
        type: HeadingBlockKeys.type,
        attributes: {
          HeadingBlockKeys.level: 2,
          HeadingBlockKeys.delta: node.delta!.toJson(),
        },
      ),
    );

    expect(changes, hasLength(1));
    expect(changes.single.single.id, 'paragraph-a');
    expect(changes.single.single.blockType, 'heading_2');
    expect(changes.single.single.text, 'Hello');
  });

  test('remote replacement preserves UTF-16 text content', () async {
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [
        CollabEditorBlock(id: 'emoji', blockType: 'paragraph', text: 'A😀B'),
      ],
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);

    await adapter.replaceFromRemote(const [
      CollabEditorBlock(
        id: 'emoji',
        blockType: 'paragraph',
        text: 'A😀 hello B',
      ),
    ]);

    expect(adapter.text, 'A😀 hello B');
  });

  test('publishes supported inline styles as rich-text segments', () async {
    final changes = <List<CollabEditorBlock>>[];
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [initial],
      onLocalBlocksChanged: changes.add,
    );
    addTearDown(adapter.dispose);
    final node = adapter.editorState.document.first!;

    final transaction = adapter.editorState.transaction
      ..formatText(node, 0, 5, {
        AppFlowyRichTextKeys.bold: true,
        AppFlowyRichTextKeys.strikethrough: true,
        AppFlowyRichTextKeys.textColor: '0xff2196f3',
        AppFlowyRichTextKeys.backgroundColor: '0x4dffc107',
      });
    await adapter.editorState.apply(transaction);

    expect(changes, hasLength(1));
    expect(changes.single.single.segments, const [
      CollabEditorTextSegment(
        text: 'Hello',
        bold: true,
        strikethrough: true,
        textColor: '0xff2196f3',
        backgroundColor: '0x4dffc107',
      ),
    ]);
  });

  test(
    'applies remote rich text and todo checked state without echo',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'task',
            blockType: 'todo_list',
            text: 'Ship editor',
          ),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      final originalNode = adapter.editorState.document.first!;

      await adapter.replaceFromRemote(const [
        CollabEditorBlock(
          id: 'task',
          blockType: 'todo_list',
          text: 'Ship editor',
          checked: true,
          segments: [
            CollabEditorTextSegment(text: 'Ship', bold: true),
            CollabEditorTextSegment(
              text: ' editor',
              italic: true,
              textColor: '0xfff44336',
              backgroundColor: '0x4d2196f3',
            ),
          ],
        ),
      ]);

      final node = adapter.editorState.document.first!;
      expect(node, same(originalNode));
      expect(node.type, TodoListBlockKeys.type);
      expect(node.attributes[TodoListBlockKeys.checked], isTrue);
      expect(node.delta!.first.attributes?[AppFlowyRichTextKeys.bold], isTrue);
      expect(node.delta!.last.attributes?[AppFlowyRichTextKeys.italic], isTrue);
      expect(
        node.delta!.last.attributes?[AppFlowyRichTextKeys.textColor],
        '0xfff44336',
      );
      expect(
        node.delta!.last.attributes?[AppFlowyRichTextKeys.backgroundColor],
        '0x4d2196f3',
      );
      expect(changes, isEmpty);
    },
  );

  test(
    'an empty canonical document keeps one editable local paragraph',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(onLocalBlocksChanged: (_) {});
      addTearDown(adapter.dispose);
      final id = adapter.blocks.single.id;

      await adapter.replaceFromRemote(const []);

      expect(adapter.blocks, [
        CollabEditorBlock(id: id, blockType: 'paragraph', text: ''),
      ]);
    },
  );
}
