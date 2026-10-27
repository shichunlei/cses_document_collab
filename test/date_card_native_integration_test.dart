import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_date_card.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/api/collab/history.dart' as history;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 发布Schema夹具经真实FRB/Yrs/原生历史/SQLite验证；缺库失败，不跳过。
void main() {
  setUpAll(() async {
    final suffix = Platform.isMacOS ? 'dylib' : 'so';
    final library = File('rust/target/debug/libcses_collab_core.$suffix');
    expect(library.existsSync(), isTrue, reason: '先在包目录执行cargo build --manifest-path rust/Cargo.toml');
    await RustLib.init(externalLibrary: ExternalLibrary.open(library.absolute.path));
  });

  test('desktop date cards cross adapter/native history and SQLite reopen', () async {
    final dir = await Directory.systemTemp.createTemp('date-card-frb-');
    AppFlowyBlockEditorAdapter? adapter;
    try {
      final database = '${dir.path}/updates.sqlite';
      native.openCsesDocument(documentId: 'fixture-doc', cacheDocumentId: 'date-cache', databasePath: database);
      native.applyDocumentUpdate(bytes: await File('rust/tests/fixtures/blockcraft-date-card.update').readAsBytes());
      history.configureDocumentHistory(editable: true);
      final initial = native.currentBlocks();
      expect(initial.where((b) => b.blockType == 'date-card'), hasLength(13));
      adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: initial.map(_local).toList(),
        onLocalBlocksChanged: (blocks) => history.applyHistorySnapshot(blocks: blocks.map(_native).toList()),
      );
      final state = adapter.editorState;
      final originalNode = state.document.root.children.first;
      expect(
        await changeCollabDateCardProperties(state, 'date-0', {'style': 'pill', 'format': 'min', 'fg': '#123456'}),
        isTrue,
      );
      expect(history.documentHistoryState().undoDepth, 1);
      var props = jsonDecode(native.currentBlocks().first.resource!.properties) as Map;
      expect(props['date'], '2026-10-25T09:30');
      expect(props['style'], 'pill');
      final undo = history.undoDocument();
      await adapter.replaceFromRemote(undo.blocks.map(_local).toList());
      expect(identical(state.document.root.children.first, originalNode), isTrue);
      expect(adapter.blocks.first.resource!.values['style'], 'calendar');
      final redo = history.redoDocument();
      await adapter.replaceFromRemote(redo.blocks.map(_local).toList());
      expect(adapter.blocks.first.resource!.values['style'], 'pill');
      final landing = await insertCollabDateCard(state, Selection.single(path: [12], startOffset: 1));
      expect(landing, isNotNull);
      final inserted = adapter.blocks.firstWhere(
        (b) =>
            b.id != 'date-0' &&
            b.resource?.values['date'] != null &&
            b.resource!.values['date'] != '2026-10-25T09:30' &&
            b.id != 'nested-date',
      );
      expect(native.currentBlocks().any((b) => b.id == inserted.id), isTrue);
      native.closeDocument();
      final reopened = native.openCsesDocument(
        documentId: 'fixture-doc',
        cacheDocumentId: 'date-cache',
        databasePath: database,
      );
      expect(reopened.blocks.where((b) => b.blockType == 'date-card'), hasLength(14));
      props = jsonDecode(reopened.blocks.first.resource!.properties) as Map;
      expect(props['style'], 'pill');
      expect(props['date'], '2026-10-25T09:30');
      expect(reopened.blocks.first.text, isEmpty);
    } finally {
      adapter?.dispose();
      native.closeDocument();
      await dir.delete(recursive: true);
    }
  });

  test('local draft insert and field edits survive native undo redo and reopen', () async {
    final dir = await Directory.systemTemp.createTemp('date-card-draft-');
    final database = '${dir.path}/updates.sqlite';
    final owner = CollabController.localDraft(databasePath: database);
    try {
      await owner.initialize();
      final state = owner.editorState;
      expect(await insertCollabDateCard(state, Selection.single(path: [0], startOffset: 0)), isNotNull);
      final date = owner.editorState.document.root.children.first;
      final id = date.attributes['cses_collab_block_id'] as String;
      expect(await changeCollabDateCardProperty(state, id, 'style', 'rail'), isTrue);
      expect(jsonDecode(native.currentBlocks().first.resource!.properties)['style'], 'rail');
      await pumpEventQueue();
      expect(owner.canUndo, isTrue);
      await owner.undo();
      expect(jsonDecode(native.currentBlocks().first.resource!.properties).containsKey('style'), isFalse);
      await owner.redo();
      expect(jsonDecode(native.currentBlocks().first.resource!.properties)['style'], 'rail');
      await owner.close();
      final reopened = CollabController.localDraft(databasePath: database);
      try {
        await reopened.initialize();
        expect(reopened.editorState.document.root.children.first.type, 'date-card');
        expect(jsonDecode(native.currentBlocks().first.resource!.properties)['style'], 'rail');
      } finally {
        await reopened.close();
      }
    } finally {
      await owner.close();
      await dir.delete(recursive: true);
    }
  });
}

/// 将借用的原生 [block] 映射到正式编辑器；不创建持久化或网络会话。
CollabEditorBlock _local(native.CollabBlock block) => CollabEditorBlock(
  id: block.id,
  parentId: block.parentId,
  blockType: block.blockType,
  text: block.text,
  resource: block.resource == null ? null : CollabResource(properties: block.resource!.properties),
  calloutPrefix: block.calloutPrefix,
);

/// 将 [block] 显式字段补丁交给原生同一事务，保留资源的缺失/null区别。
native.CollabBlock _native(CollabEditorBlock block) => native.CollabBlock(
  id: block.id,
  parentId: block.parentId,
  blockType: block.blockType,
  text: block.text,
  segments: const [],
  checked: block.checked,
  alignment: block.alignment,
  indent: block.indent,
  calloutPrefix: block.calloutPrefix,
  resource: block.resource == null
      ? null
      : native.CollabResource(properties: block.resource!.properties, propertyEdits: block.resource!.propertyEdits),
);
