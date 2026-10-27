import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_text_box.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/api/collab/history.dart' as history;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证文本框经真实FRB、原生历史和SQLite保存重开；缺库直接失败。
void main() {
  setUpAll(() async {
    final suffix = Platform.isMacOS ? 'dylib' : 'so';
    final library = File('rust/target/debug/libcses_collab_core.$suffix');
    expect(library.existsSync(), isTrue);
    await RustLib.init(externalLibrary: ExternalLibrary.open(library.absolute.path));
  });
  test('text-box fields, text, delete history and SQLite reopen preserve desktop data', () async {
    final dir = await Directory.systemTemp.createTemp('text-box-frb-');
    AppFlowyBlockEditorAdapter? adapter;
    try {
      final database = '${dir.path}/updates.sqlite';
      native.openCsesDocument(documentId: 'fixture-doc', cacheDocumentId: 'box-cache', databasePath: database);
      native.applyDocumentUpdate(bytes: await File('rust/tests/fixtures/blockcraft-text-box.update').readAsBytes());
      history.configureDocumentHistory(editable: true);
      adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: native.currentBlocks().map(_local).toList(),
        onLocalBlocksChanged: (blocks) => history.applyHistorySnapshot(blocks: blocks.map(_native).toList()),
      );
      final state = adapter.editorState;
      expect(await updateCollabTextBox(state, 'text-box', {'width': 360}), isTrue);
      expect(jsonDecode(native.currentBlocks().first.resource!.properties)['width'], 360);
      await adapter.replaceFromRemote(history.undoDocument().blocks.map(_local).toList());
      expect(readCollabTextBox(state.document.root.children.first.attributes).values['width'], 300);
      await adapter.replaceFromRemote(history.redoDocument().blocks.map(_local).toList());
      final body = state.getNodeAtPath([0, 0])!;
      await state.apply(state.transaction..insertText(body, body.delta!.length, '手机'), withUpdateSelection: false);
      expect(native.currentBlocks().firstWhere((b) => b.id == 'box-body').text, '文本框正文手机');
      expect(await deleteCollabTextBox(state, 'text-box'), isTrue);
      expect(native.currentBlocks().any((b) => b.id == 'box-body'), isFalse);
      await adapter.replaceFromRemote(history.undoDocument().blocks.map(_local).toList());
      expect(native.currentBlocks().firstWhere((b) => b.id == 'box-body').parentId, 'text-box');
      native.closeDocument();
      final reopened = native.openCsesDocument(
        documentId: 'fixture-doc',
        cacheDocumentId: 'box-cache',
        databasePath: database,
      );
      expect(reopened.blocks.firstWhere((b) => b.id == 'box-body').text, '文本框正文手机');
      expect(jsonDecode(reopened.blocks.first.resource!.properties)['width'], 360);
      expect(reopened.blocks.last.blockType, 'unsupported');
    } finally {
      adapter?.dispose();
      native.closeDocument();
      await dir.delete(recursive: true);
    }
  });
  test('local draft inserts a text-box with field history and persists it across reopen', () async {
    final dir = await Directory.systemTemp.createTemp('text-box-local-');
    final database = '${dir.path}/draft.sqlite';
    final owner = CollabController.localDraft(databasePath: database);
    try {
      await owner.initialize();
      expect(await insertCollabTextBox(owner.editorState, Selection.single(path: [0], startOffset: 0)), isNotNull);
      await pumpEventQueue();
      final node = owner.editorState.document.root.children.first;
      final id = node.attributes['cses_collab_block_id'] as String;
      expect(await updateCollabTextBox(owner.editorState, id, {'fill': '#FFF3C4'}), isTrue);
      await pumpEventQueue();
      await owner.undo();
      expect(
        readCollabTextBox(owner.editorState.document.root.children.first.attributes).values.containsKey('fill'),
        isFalse,
      );
      await owner.redo();
      expect(readCollabTextBox(owner.editorState.document.root.children.first.attributes).values['fill'], '#FFF3C4');
      await owner.close();
      final reopened = CollabController.localDraft(databasePath: database);
      try {
        await reopened.initialize();
        expect(reopened.editorState.document.root.children.first.type, 'text-box');
        expect(reopened.editorState.document.root.children.first.children.single.delta!.isEmpty, isTrue);
        expect(
          readCollabTextBox(reopened.editorState.document.root.children.first.attributes).values['fill'],
          '#FFF3C4',
        );
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
