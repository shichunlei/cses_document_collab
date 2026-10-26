import 'dart:io';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_columns.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/api/collab/history.dart' as history;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 独立审查反例；断言期望的安全行为，不修改生产代码。
void main() {
  setUpAll(() async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(File('rust/target/debug/libcses_collab_core.dylib').absolute.path),
    );
  });

  test('R1 forward delete at left-column end must not consume right-column content', () async {
    final adapter = _adapter();
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    state.selectionType = SelectionType.inline;
    state.selection = Selection.single(path: [0, 0, 0], startOffset: 3);
    deleteCommand.execute(state);
    await pumpEventQueue();
    expect(
      {
        'left': adapter.blocks.firstWhere((b) => b.id == 'left-text').text,
        'right': adapter.blocks.where((b) => b.id == 'right-text').map((b) => b.text).toList(),
      },
      {
        'left': '第一列',
        'right': ['第二列'],
      },
    );
  });

  test('R1 word-backspace at right-column start must not merge into the left column', () async {
    final adapter = _adapter();
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    state.selectionType = SelectionType.inline;
    state.selection = Selection.single(path: [0, 1, 0], startOffset: 0);
    deleteLeftWordCommand.execute(state);
    await pumpEventQueue();
    expect(
      {
        'left': adapter.blocks.firstWhere((b) => b.id == 'left-text').text,
        'right': adapter.blocks.where((b) => b.id == 'right-text').map((b) => b.text).toList(),
      },
      {
        'left': '第一列',
        'right': ['第二列'],
      },
    );
  });

  test('R2 legacy persisted snapshot columns retain width/count on JSON export', () {
    final snapshot =
        jsonDecode(File('rust/tests/fixtures/blockcraft-columns.json').readAsStringSync()) as Map<String, dynamic>;
    snapshot['children'] = [(snapshot['children'] as List).first];
    final fresh = BlockCraftJsonCodec.decode(snapshot);

    /// 将借用[node]还原为此前落盘的snapshot-columns/column布局，没有正式资源投影字段。
    Node legacy(Node node) => Node(
      type: collabColumnsTypes.contains(node.type) ? 'snapshot-${node.type}' : node.type,
      id: node.id,
      attributes: {
        for (final e in node.attributes.entries)
          if (!collabColumnsTypes.contains(node.type) || e.key.startsWith('bc.')) e.key: e.value,
      },
      children: node.children.map(legacy).toList(),
    );
    final saved = Document(root: legacy(fresh.root));
    final reopened = Document.fromJson(saved.toJson());
    addTearDown(fresh.dispose);
    addTearDown(saved.dispose);
    addTearDown(reopened.dispose);
    final exported = BlockCraftJsonCodec.encode(reopened);
    final group = (exported['children'] as List).first as Map;
    expect(
      {
        'columnWidths': group['props']['columnWidths'],
        'columnCount': group['props']['columnCount'],
        'columnIndex': group['children'][0]['props']['columnIndex'],
      },
      {
        'columnWidths': [30, 70],
        'columnCount': 2,
        'columnIndex': 0,
      },
    );
  });

  testWidgets('preview of an empty column contains no body insertion control', (tester) async {
    final doc = Document(
      root: Node(
        type: 'page',
        children: [
          Node(
            type: 'columns',
            children: [
              Node(type: 'column'),
              Node(type: 'column'),
            ],
          ),
        ],
      ),
    );
    final owner = DocumentEditorController(document: doc);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DocumentEditorView(editorState: owner.editorState, preview: true)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('添加正文'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(owner.close);
  });

  test('native word-backspace at a column boundary must preserve both columns', () async {
    final dir = await Directory.systemTemp.createTemp('columns-boundary-review-');
    AppFlowyBlockEditorAdapter? adapter;
    try {
      native.openCsesDocument(
        documentId: 'fixture-doc',
        cacheDocumentId: 'boundary-review',
        databasePath: '${dir.path}/db.sqlite',
      );
      native.applyDocumentUpdate(bytes: File('rust/tests/fixtures/blockcraft-columns.update').readAsBytesSync());
      history.configureDocumentHistory(editable: true);
      adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: native.currentBlocks().map(_local).toList(),
        onLocalBlocksChanged: (blocks) => history.applyHistorySnapshot(blocks: blocks.map(_native).toList()),
      );
      final state = adapter.editorState;
      state.selectionType = SelectionType.inline;
      state.selection = Selection.single(path: [0, 1, 0], startOffset: 0);
      deleteLeftWordCommand.execute(state);
      await pumpEventQueue();
      final current = native.currentBlocks();
      expect(
        {
          'left': current.firstWhere((b) => b.id == 'body-0').text,
          'right': current.where((b) => b.id == 'body-1').map((b) => b.text).toList(),
        },
        {
          'left': '第1列正文',
          'right': ['第2列正文'],
        },
      );
    } finally {
      adapter?.dispose();
      native.closeDocument();
      await dir.delete(recursive: true);
    }
  });

  test('native delete column, undo redo and structure restore remain valid', () async {
    final dir = await Directory.systemTemp.createTemp('columns-review-');
    AppFlowyBlockEditorAdapter? adapter;
    try {
      native.openCsesDocument(
        documentId: 'fixture-doc',
        cacheDocumentId: 'review',
        databasePath: '${dir.path}/db.sqlite',
      );
      native.applyDocumentUpdate(bytes: File('rust/tests/fixtures/blockcraft-columns.update').readAsBytesSync());
      history.configureDocumentHistory(editable: true);
      adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: native.currentBlocks().map(_local).toList(),
        onLocalBlocksChanged: (blocks) => history.applyHistorySnapshot(blocks: blocks.map(_native).toList()),
      );
      expect(await editCollabColumns(adapter.editorState, 'columns', 'remove', columnId: 'column-0'), isTrue);
      expect(native.currentBlocks().first.id, 'body-1');
      for (var i = 0; i < 3; i++) {
        await adapter.replaceFromRemote(history.undoDocument().blocks.map(_local).toList());
        expect(native.currentBlocks().firstWhere((b) => b.id == 'body-0').parentId, 'column-0');
        await adapter.replaceFromRemote(history.redoDocument().blocks.map(_local).toList());
        expect(native.currentBlocks().first.id, 'body-1');
      }
    } finally {
      adapter?.dispose();
      native.closeDocument();
      await dir.delete(recursive: true);
    }
  });
}

/// 创建借用测试正文的正式适配器，由调用者dispose。
AppFlowyBlockEditorAdapter _adapter() => AppFlowyBlockEditorAdapter(
  initialBlocks: [
    CollabEditorBlock(
      id: 'columns',
      blockType: 'columns',
      text: '',
      resource: CollabResource.fromValues({
        'columnCount': 2,
        'columnWidths': [50, 50],
      }),
    ),
    const CollabEditorBlock(id: 'left', parentId: 'columns', blockType: 'column', text: ''),
    const CollabEditorBlock(id: 'left-text', parentId: 'left', blockType: 'paragraph', text: '第一列'),
    const CollabEditorBlock(id: 'right', parentId: 'columns', blockType: 'column', text: ''),
    const CollabEditorBlock(id: 'right-text', parentId: 'right', blockType: 'paragraph', text: '第二列'),
    const CollabEditorBlock(id: 'tail', blockType: 'paragraph', text: '后续'),
  ],
  onLocalBlocksChanged: (_) {},
);

/// 将借用的原生 [block] 映射到正式编辑器；不创建持久化或网络会话。
CollabEditorBlock _local(native.CollabBlock block) => CollabEditorBlock(
  id: block.id,
  parentId: block.parentId,
  blockType: block.blockType,
  text: block.text,
  resource: block.resource == null ? null : CollabResource(properties: block.resource!.properties),
  calloutPrefix: block.calloutPrefix,
  segments: block.segments.map((s) => CollabEditorTextSegment(text: s.text, bold: s.bold)).toList(),
);

/// 将 [block] 显式字段补丁交给原生同一事务，保留资源的缺失/null区别。
native.CollabBlock _native(CollabEditorBlock block) => native.CollabBlock(
  id: block.id,
  parentId: block.parentId,
  blockType: block.blockType,
  text: block.text,
  segments: block.segments
      .map(
        (s) => native.CollabTextSegment(
          text: s.text,
          bold: s.bold,
          italic: false,
          underline: false,
          strikethrough: false,
          code: false,
          superscript: false,
          subscript: false,
        ),
      )
      .toList(),
  checked: block.checked,
  alignment: block.alignment,
  indent: block.indent,
  calloutPrefix: block.calloutPrefix,
  resource: block.resource == null
      ? null
      : native.CollabResource(properties: block.resource!.properties, propertyEdits: block.resource!.propertyEdits),
);
