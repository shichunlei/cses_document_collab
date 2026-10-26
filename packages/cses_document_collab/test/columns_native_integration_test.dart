import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:flutter/widgets.dart';
import 'package:cses_document_collab/src/model/collab_columns.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/api/collab/history.dart' as history;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实FRB/Yrs历史与SQLite的分栏往返，缺少原生库时明确失败。
void main() {
  setUpAll(() async {
    final suffix = Platform.isMacOS ? 'dylib' : 'so';
    final library = File('rust/target/debug/libcses_collab_core.$suffix');
    expect(library.existsSync(), isTrue);
    await RustLib.init(externalLibrary: ExternalLibrary.open(library.absolute.path));
  });

  test('published columns cross FRB field history, text edits, structure undo redo and reopen', () async {
    final dir = await Directory.systemTemp.createTemp('columns-frb-');
    AppFlowyBlockEditorAdapter? adapter;
    try {
      final database = '${dir.path}/updates.sqlite';
      native.openCsesDocument(documentId: 'fixture-doc', cacheDocumentId: 'columns-cache', databasePath: database);
      native.applyDocumentUpdate(bytes: await File('rust/tests/fixtures/blockcraft-columns.update').readAsBytes());
      history.configureDocumentHistory(editable: true);
      adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: native.currentBlocks().map(_local).toList(),
        onLocalBlocksChanged: (blocks) => history.applyHistorySnapshot(blocks: blocks.map(_native).toList()),
      );
      final state = adapter.editorState;
      expect(await editCollabColumns(state, 'columns', 'widen', columnId: 'column-0'), isTrue);
      expect(jsonDecode(native.currentBlocks().first.resource!.properties)['columnWidths'], [35, 65]);
      expect(history.documentHistoryState().undoDepth, 1);
      await adapter.replaceFromRemote(history.undoDocument().blocks.map(_local).toList());
      expect(collabColumnWidths(state.document.root.children.first), [30, 70]);
      await adapter.replaceFromRemote(history.redoDocument().blocks.map(_local).toList());
      expect(collabColumnWidths(state.document.root.children.first), [35, 65]);
      expect(await editCollabColumns(state, 'columns', 'add'), isTrue);
      expect(native.currentBlocks().where((b) => b.parentId == 'columns'), hasLength(3));
      await adapter.replaceFromRemote(history.undoDocument().blocks.map(_local).toList());
      expect(native.currentBlocks().where((b) => b.parentId == 'columns'), hasLength(2));
      await adapter.replaceFromRemote(history.redoDocument().blocks.map(_local).toList());
      expect(native.currentBlocks().where((b) => b.parentId == 'columns'), hasLength(3));
      expect(await editCollabColumns(state, 'columns', 'right', columnId: 'column-0'), isTrue);
      expect(native.currentBlocks().where((b) => b.parentId == 'columns').map((b) => b.id).first, 'column-1');
      expect(await editCollabColumns(state, 'columns', 'flatten'), isTrue);
      expect(native.currentBlocks().firstWhere((b) => b.id == 'body-0').parentId, isNull);
      await adapter.replaceFromRemote(history.undoDocument().blocks.map(_local).toList());
      expect(native.currentBlocks().firstWhere((b) => b.id == 'body-0').parentId, 'column-0');
      final paragraph = state.document.root.children.first.children[1].children.first;
      await state.apply(
        state.transaction..insertText(paragraph, paragraph.delta!.length, '手机'),
        withUpdateSelection: false,
      );
      expect(native.currentBlocks().firstWhere((b) => b.id == 'body-0').text, '第1列正文手机');
      native.closeDocument();
      final reopened = native.openCsesDocument(
        documentId: 'fixture-doc',
        cacheDocumentId: 'columns-cache',
        databasePath: database,
      );
      expect(reopened.blocks.where((b) => b.parentId == 'columns'), hasLength(3));
      expect(reopened.blocks.firstWhere((b) => b.id == 'body-0').text, '第1列正文手机');
      history.configureDocumentHistory(editable: true);
      final tailNode = state.document.root.children.firstWhere((n) => n.delta != null);
      expect(await insertCollabColumns(state, Selection.single(path: tailNode.path, startOffset: 0)), isNotNull);
      expect(native.currentBlocks().where((b) => b.blockType == 'columns'), hasLength(3));
    } finally {
      adapter?.dispose();
      native.closeDocument();
      await dir.delete(recursive: true);
    }
  });

  test('word-backspace column boundary leaves native history and SQLite content unchanged', () async {
    final dir = await Directory.systemTemp.createTemp('columns-boundary-fixed-');
    AppFlowyBlockEditorAdapter? adapter;
    try {
      final database = '${dir.path}/updates.sqlite';
      native.openCsesDocument(documentId: 'fixture-doc', cacheDocumentId: 'boundary-fixed', databasePath: database);
      native.applyDocumentUpdate(bytes: await File('rust/tests/fixtures/blockcraft-columns.update').readAsBytes());
      history.configureDocumentHistory(editable: true);
      var writes = 0;
      adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: native.currentBlocks().map(_local).toList(),
        onLocalBlocksChanged: (blocks) {
          writes++;
          history.applyHistorySnapshot(blocks: blocks.map(_native).toList());
        },
      );
      final state = adapter.editorState;
      final commands = [collabBlockBackspaceCommand, ...standardCommandShortcutEvents];
      final bound = commands.firstWhere(
        (event) => event.keybindings.contains(deleteLeftWordCommand.keybindings.single),
      );
      expect(bound, same(collabBlockBackspaceCommand));
      state.selectionType = SelectionType.inline;
      state.selection = Selection.single(path: [0, 1, 0], startOffset: 0);
      expect(bound.execute(state), KeyEventResult.handled);
      await pumpEventQueue();
      expect(writes, 0);
      expect(history.documentHistoryState().undoDepth, 0);
      expect(native.currentBlocks().firstWhere((b) => b.id == 'body-0').text, '第1列正文');
      expect(native.currentBlocks().firstWhere((b) => b.id == 'body-1').text, '第2列正文');
      native.closeDocument();
      final reopened = native.openCsesDocument(
        documentId: 'fixture-doc',
        cacheDocumentId: 'boundary-fixed',
        databasePath: database,
      );
      expect(reopened.blocks.firstWhere((b) => b.id == 'body-1').parentId, 'column-1');
      expect(reopened.blocks.firstWhere((b) => b.id == 'body-1').text, '第2列正文');
      expect(reopened.blocks.firstWhere((b) => b.id == 'body-0').text, '第1列正文');
    } finally {
      adapter?.dispose();
      native.closeDocument();
      await dir.delete(recursive: true);
    }
  });

  test('local draft columns insert, field history and reopen use the public controller', () async {
    final dir = await Directory.systemTemp.createTemp('columns-draft-');
    final database = '${dir.path}/updates.sqlite';
    final owner = CollabController.localDraft(databasePath: database);
    try {
      await owner.initialize();
      expect(await insertCollabColumns(owner.editorState, Selection.single(path: [0], startOffset: 0)), isNotNull);
      await pumpEventQueue();
      final columns = owner.editorState.document.root.children.first;
      final id = columns.attributes['cses_collab_block_id'] as String;
      expect(await editCollabColumns(owner.editorState, id, 'add'), isTrue);
      expect(native.currentBlocks().where((b) => b.parentId == id), hasLength(3));
      await pumpEventQueue();
      await owner.undo();
      expect(native.currentBlocks().where((b) => b.parentId == id), hasLength(2));
      await owner.redo();
      expect(native.currentBlocks().where((b) => b.parentId == id), hasLength(3));
      await owner.close();
      final reopened = CollabController.localDraft(databasePath: database);
      try {
        await reopened.initialize();
        expect(reopened.editorState.document.root.children.first.children, hasLength(3));
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
