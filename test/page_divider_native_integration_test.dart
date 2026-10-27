import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_page_divider.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 使用发布 Schema 夹具验证真实 adapter/FRB/Yrs/SQLite；缺库直接失败。
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
    'published page breaks retain void structure through insert/delete/history and SQLite reopen',
    () async {
      final dir = await Directory.systemTemp.createTemp('page-divider-frb-');
      AppFlowyBlockEditorAdapter? adapter;
      try {
        final database = '${dir.path}/updates.sqlite';
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'break-cache',
          databasePath: database,
        );
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-page-divider.update',
          ).readAsBytes(),
        );
        expect(native.documentReadOnlyReason(), isNull);
        final initial = native.currentBlocks();
        expect(initial.take(2).map((b) => b.blockType), [
          'page-divider',
          'page-divider',
        ]);
        expect(
          initial.where((b) => b.blockType == 'unsupported').map((b) => b.id),
          ['nested-break', 'malformed-break'],
        );
        adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: initial
              .map(
                (b) => CollabEditorBlock(
                  id: b.id,
                  parentId: b.parentId,
                  blockType: b.blockType,
                  text: b.text,
                  calloutPrefix: b.calloutPrefix,
                ),
              )
              .toList(),
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
                    ),
                  )
                  .toList(),
            );
          },
        );
        final state = adapter.editorState;
        final landing = await insertCollabPageDivider(
          state,
          Selection.single(path: [2], startOffset: 1),
        );
        expect(landing, isNotNull);
        final inserted = adapter.blocks[3];
        expect(inserted.blockType, 'page-divider');
        expect(native.currentBlocks()[3].id, inserted.id);
        expect(await deleteCollabPageDivider(state, inserted.id), isTrue);
        expect(native.currentBlocks().any((b) => b.id == inserted.id), isFalse);
        state.undoManager.undo();
        await pumpEventQueue();
        expect(
          native.currentBlocks().firstWhere((b) => b.id == inserted.id).text,
          isEmpty,
        );
        state.undoManager.redo();
        await pumpEventQueue();
        expect(native.currentBlocks().any((b) => b.id == inserted.id), isFalse);
        state.undoManager.undo();
        await pumpEventQueue();
        native.closeDocument();
        final reopened = native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'break-cache',
          databasePath: database,
        );
        expect(
          reopened.blocks.where((b) => b.blockType == 'page-divider').length,
          3,
        );
        expect(
          reopened.blocks.firstWhere((b) => b.id == inserted.id).parentId,
          isNull,
        );
        expect(
          reopened.blocks
              .where((b) => b.blockType == 'page-divider')
              .every((b) => b.text.isEmpty && b.segments.isEmpty),
          isTrue,
        );
      } finally {
        adapter?.dispose();
        native.closeDocument();
        await dir.delete(recursive: true);
      }
    },
  );
}
