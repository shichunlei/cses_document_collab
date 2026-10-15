import 'dart:io';

import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实FRB、桌面Yjs合成数据与SQLite恢复；缺少原生库直接失败。
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
    'meeting/task/doc atoms restore metadata and reopen with user and formula',
    () async {
      final directory = await Directory.systemTemp.createTemp('entity-frb-');
      final database = '${directory.path}/updates.sqlite';
      try {
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'entity-cache',
          databasePath: database,
        );
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-entity-mention.update',
          ).readAsBytes(),
        );
        expect(native.documentReadOnlyReason(), isNull);
        final original = native.currentBlocks();
        final body = original.first;
        expect(
          body.segments
              .where((s) => s.mentionType != null)
              .map((s) => s.mentionType),
          ['meeting', 'task', 'doc'],
        );
        expect(
          body.segments.where((s) => s.inlineMention != null),
          hasLength(4),
        );
        for (final kind in ['meeting', 'task', 'doc']) {
          final segments = body.segments
              .where((s) => s.mentionType != kind)
              .toList();
          final deleted = [...original];
          deleted[0] = native.CollabBlock(
            id: body.id,
            blockType: body.blockType,
            text: segments.map((s) => s.text).join(),
            segments: segments,
            checked: body.checked,
            alignment: body.alignment,
            indent: body.indent,
          );
          expect(
            native.applyBlockSnapshot(blocks: deleted).v1Update,
            isNotEmpty,
          );
          expect(
            native.applyBlockSnapshot(blocks: original).v1Update,
            isNotEmpty,
          );
          expect(
            native.currentBlocks().first.segments.map(
              (s) => s.mentionAttributes,
            ),
            body.segments.map((s) => s.mentionAttributes),
          );
        }
        native.closeDocument();
        final restored = native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'entity-cache',
          databasePath: database,
        );
        expect(native.documentReadOnlyReason(), isNull);
        expect(
          restored.blocks.first.segments.map(
            (s) => (
              s.text,
              s.inlineMention,
              s.mentionId,
              s.mentionType,
              s.mentionAttributes,
            ),
          ),
          body.segments.map(
            (s) => (
              s.text,
              s.inlineMention,
              s.mentionId,
              s.mentionType,
              s.mentionAttributes,
            ),
          ),
        );
        expect(restored.blocks.last.parentId, 'entity-callout');
      } finally {
        native.closeDocument();
        await directory.delete(recursive: true);
      }
    },
  );
}
