import 'dart:io';

import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用桌面Schema夹具验证真实FRB投影、异常保护、引用增删和SQLite恢复；缺库视为失败。
void main() {
  test(
    'desktop KR crosses FRB and SQLite without freezing business data',
    () async {
      final library = File(
        'rust/target/debug/libcses_collab_core.${Platform.isMacOS ? 'dylib' : 'so'}',
      );
      expect(
        library.existsSync(),
        true,
        reason: '先执行 cargo build --manifest-path rust/Cargo.toml',
      );
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(library.absolute.path),
      );
      final directory = await Directory.systemTemp.createTemp('kr-frb-');
      final database = '${directory.path}/updates.sqlite';
      try {
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'kr-cache',
          databasePath: database,
        );
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-kr.update',
          ).readAsBytes(),
        );
        final before = native.currentBlocks();
        expect(before.map((b) => b.blockType), [
          'kr-list',
          'paragraph',
          'unsupported',
          'unsupported',
        ]);
        expect(before.first.resource!.properties, '{"meetingId":"m1"}');
        expect(before.first.text, '');
        final inserted = native.CollabBlock(
          id: 'new-kr',
          blockType: 'kr-list',
          text: '',
          segments: [],
          checked: false,
          alignment: 'left',
          indent: 0,
          resource: native.CollabResource(properties: '{"meetingId":"m2"}'),
        );
        native.applyBlockSnapshot(blocks: [...before, inserted]);
        expect(
          native.currentBlocks().last.resource!.properties,
          '{"meetingId":"m2"}',
        );
        native.applyBlockSnapshot(blocks: before);
        expect(native.currentBlocks().length, before.length);
        native.applyBlockSnapshot(blocks: [...before, inserted]);
        native.closeDocument();
        final restored = native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'kr-cache',
          databasePath: database,
        );
        expect(restored.blocks.last.blockType, 'kr-list');
        expect(restored.blocks.last.resource!.properties, '{"meetingId":"m2"}');
        expect(
          restored.blocks.first.resource!.properties,
          '{"meetingId":"m1"}',
        );
      } finally {
        native.closeDocument();
        await directory.delete(recursive: true);
      }
    },
  );
}
