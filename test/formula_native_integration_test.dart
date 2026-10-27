import 'dart:io';

import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实 FRB 与 SQLite 恢复回归；缺少宿主库直接失败，不将跳过当作通过。
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
      reason: '先在本包执行 cargo build --manifest-path rust/Cargo.toml',
    );
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(library.absolute.path),
    );
  });
  test(
    'desktop formula props cross FRB, field edits and SQLite reopen',
    () async {
      final dir = await Directory.systemTemp.createTemp('formula-frb-');
      final database = '${dir.path}/updates.sqlite';
      try {
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'formula-cache',
          databasePath: database,
        );
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-formula.update',
          ).readAsBytes(),
        );
        expect(native.documentReadOnlyReason(), isNull);
        final blocks = native.currentBlocks();
        final index = blocks.indexWhere((b) => b.id == 'formula-1');
        final original = blocks[index];
        expect(original.text, isEmpty);
        expect(original.segments, isEmpty);
        expect(blocks.where((b) => b.blockType == 'formula').length, 5);
        blocks[index] = native.CollabBlock(
          id: original.id,
          blockType: original.blockType,
          text: original.text,
          segments: original.segments,
          checked: original.checked,
          alignment: original.alignment,
          indent: original.indent,
          resource: native.CollabResource(
            properties: original.resource!.properties,
            propertyEdits: '{"latex":{"value":"x^2+y^2"}}',
          ),
          blockBackgroundColor: original.blockBackgroundColor,
          blockBorderColor: original.blockBorderColor,
        );
        expect(native.applyBlockSnapshot(blocks: blocks).v1Update, isNotEmpty);
        final properties = native.currentBlocks()[index].resource!.properties;
        expect(properties, contains('x^2+y^2'));
        native.closeDocument();
        final restored = native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'formula-cache',
          databasePath: database,
        );
        expect(restored.blocks[index].resource!.properties, properties);
        expect(restored.blocks[index].text, isEmpty);
        expect(
          restored.blocks.firstWhere((b) => b.id == 'nested-formula').parentId,
          'formula-callout',
        );
      } finally {
        native.closeDocument();
        await dir.delete(recursive: true);
      }
    },
  );
}
