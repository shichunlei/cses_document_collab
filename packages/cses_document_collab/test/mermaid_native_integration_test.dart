import 'dart:io';

import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_mermaid.dart';
import 'package:cses_document_collab/src/model/collab_mermaid_options.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'dart:convert';

/// 真实桥接和SQLite验证；缺少原生库直接失败，不将跳过计为通过。
void main() {
  setUpAll(() async {
    final library = File(
      Platform.isMacOS
          ? 'rust/target/debug/libcses_collab_core.dylib'
          : 'rust/target/debug/libcses_collab_core.so',
    );
    expect(
      library.existsSync(),
      isTrue,
      reason: '先执行 cargo build --manifest-path rust/Cargo.toml',
    );
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(library.absolute.path),
    );
  });
  test(
    'published Mermaid source crosses adapter/FRB and SQLite; insert/delete/history persist',
    () async {
      final dir = await Directory.systemTemp.createTemp('mermaid-frb-');
      AppFlowyBlockEditorAdapter? adapter;
      try {
        final database = '${dir.path}/updates.sqlite';
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'mermaid-cache',
          databasePath: database,
        );
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-mermaid.update',
          ).readAsBytes(),
        );
        expect(native.documentReadOnlyReason(), isNull);
        final initial = native.currentBlocks();
        final projected = initial
            .map(
              (b) => CollabEditorBlock(
                id: b.id,
                parentId: b.parentId,
                blockType: b.blockType,
                text: b.text,
                calloutPrefix: b.calloutPrefix,
                resource: b.resource == null
                    ? null
                    : CollabResource(properties: b.resource!.properties),
              ),
            )
            .toList();
        adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: projected,
          onLocalBlocksChanged: (blocks) {
            native.applyBlockSnapshot(
              blocks: blocks
                  .map(
                    (b) => native.CollabBlock(
                      id: b.id,
                      parentId: b.parentId,
                      blockType: b.blockType,
                      text: b.text,
                      segments: const [],
                      checked: b.checked,
                      alignment: b.alignment,
                      indent: b.indent,
                      calloutPrefix: b.calloutPrefix,
                      resource: b.resource == null
                          ? null
                          : native.CollabResource(
                              properties: b.resource!.properties,
                              propertyEdits: b.resource!.propertyEdits,
                            ),
                    ),
                  )
                  .toList(),
            );
          },
        );
        final state = adapter.editorState;
        final source = collabMermaidSource(
          findCollabMermaid(state, 'mermaid-1'),
        )!;
        expect(
          await changeCollabMermaid(
            state,
            'mermaid-1',
            'flowchart TD\nA[中文😀]-->C',
            expectedSourceId: source.id,
            expectedDelta: jsonEncode(source.delta!.toJson()),
          ),
          isTrue,
        );
        expect(
          native
              .currentBlocks()
              .firstWhere((b) => b.id == 'mermaid-source-1')
              .text,
          contains('中文😀'),
        );
        await changeCollabMermaidView(
          state,
          'mermaid-1',
          CollabMermaidView.text,
        );
        expect(
          jsonDecode(
            native
                .currentBlocks()
                .firstWhere((b) => b.id == 'mermaid-1')
                .resource!
                .properties,
          )['mode'],
          'text',
        );
        state.undoManager.undo();
        await pumpEventQueue();
        expect(
          jsonDecode(
            native
                .currentBlocks()
                .firstWhere((b) => b.id == 'mermaid-1')
                .resource!
                .properties,
          )['mode'],
          'default',
        );
        state.undoManager.redo();
        await pumpEventQueue();
        final selection = await insertCollabMermaid(
          state,
          Selection.single(path: [2], startOffset: 0),
          'sequenceDiagram\nA->>B: 新绘图',
        );
        expect(selection, isNotNull);
        expect(
          native.currentBlocks().where((b) => b.blockType == 'mermaid').length,
          3,
        );
        state.undoManager.undo();
        await pumpEventQueue();
        expect(
          native.currentBlocks().where((b) => b.blockType == 'mermaid').length,
          2,
        );
        state.undoManager.redo();
        await pumpEventQueue();
        expect(
          native.currentBlocks().where((b) => b.blockType == 'mermaid').length,
          3,
        );
        await deleteCollabMermaid(state, 'mermaid-1');
        expect(
          native.currentBlocks().any((b) => b.id == 'mermaid-source-1'),
          isFalse,
        );
        state.undoManager.undo();
        await pumpEventQueue();
        final expected = native.currentBlocks();
        expect(
          expected.firstWhere((b) => b.id == 'mermaid-source-1').text,
          contains('中文😀'),
        );
        native.closeDocument();
        final restored = native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'mermaid-cache',
          databasePath: database,
        );
        expect(
          restored.blocks.map(
            (b) => (
              b.id,
              b.parentId,
              b.blockType,
              b.text,
              b.calloutPrefix,
              b.resource?.properties,
            ),
          ),
          expected.map(
            (b) => (
              b.id,
              b.parentId,
              b.blockType,
              b.text,
              b.calloutPrefix,
              b.resource?.properties,
            ),
          ),
        );
        expect(
          restored.blocks.firstWhere((b) => b.id == 'nested-source').parentId,
          'nested-mermaid',
        );
      } finally {
        adapter?.dispose();
        native.closeDocument();
        await dir.delete(recursive: true);
      }
    },
  );
}
