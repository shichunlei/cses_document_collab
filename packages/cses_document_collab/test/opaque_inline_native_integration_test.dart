import 'dart:io';

import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 通过真实FRB与SQLite验证未知未来实体段落局部保护，原生库缺失直接失败。
void main() {
  setUpAll(() async {
    final library = File(
      Platform.isMacOS
          ? 'rust/target/debug/libcses_collab_core.dylib'
          : 'rust/target/debug/libcses_collab_core.so',
    );
    expect(library.existsSync(), isTrue);
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(library.absolute.path),
    );
  });

  test(
    'unknown entity paragraphs protect only themselves across FRB and reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'opaque-inline-frb-',
      );
      final database = '${directory.path}/updates.sqlite';
      try {
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'opaque-inline-cache',
          databasePath: database,
        );
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-opaque-mention.update',
          ).readAsBytes(),
        );
        expect(native.documentReadOnlyReason(), isNull);
        final blocks = native.currentBlocks();
        expect(
          blocks.where((b) => b.blockType == 'unsupported').map((b) => b.id),
          ['p1', 'opaque-child'],
        );
        expect(
          blocks.firstWhere((b) => b.id == 'opaque-child').parentId,
          'opaque-callout',
        );
        final title = blocks[1];
        blocks[1] = native.CollabBlock(
          id: title.id,
          blockType: title.blockType,
          text: '${title.text}手机编辑',
          segments: const [],
          checked: title.checked,
          alignment: title.alignment,
          indent: title.indent,
        );
        expect(native.applyBlockSnapshot(blocks: blocks).v1Update, isNotEmpty);
        final beforeRejectedWrite = native.encodeStateVector();
        expect(
          () => native.applyBlockSnapshot(
            blocks: blocks.where((b) => b.id != 'p1').toList(),
          ),
          throwsA(anything),
        );
        expect(
          () => native.applyBlockSnapshot(
            blocks: blocks
                .where(
                  (b) =>
                      b.id != 'opaque-callout' &&
                      b.parentId != 'opaque-callout',
                )
                .toList(),
          ),
          throwsA(anything),
        );
        expect(native.encodeStateVector(), beforeRejectedWrite);
        native.closeDocument();
        final reopened = native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'opaque-inline-cache',
          databasePath: database,
        );
        expect(native.documentReadOnlyReason(), isNull);
        expect(
          reopened.blocks.map((b) => (b.id, b.blockType, b.text, b.parentId)),
          blocks.map((b) => (b.id, b.blockType, b.text, b.parentId)),
        );
        expect(native.encodeStateVector(), beforeRejectedWrite);
      } finally {
        native.closeDocument();
        await directory.delete(recursive: true);
      }
    },
  );
}
