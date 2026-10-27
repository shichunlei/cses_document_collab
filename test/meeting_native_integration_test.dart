import 'dart:io';

import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 会议/任务引用的真实FRB与SQLite恢复回归；缺库直接失败，不将跳过当作通过。
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
    'desktop task card crosses FRB and SQLite reopen without becoming a text block',
    () async {
      final dir = await Directory.systemTemp.createTemp('task-card-frb-');
      try {
        final database = '${dir.path}/updates.sqlite';
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'task-cache',
          databasePath: database,
        );
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-task-card.update',
          ).readAsBytes(),
        );
        expect(native.documentReadOnlyReason(), isNull);
        final original = native.currentBlocks().firstWhere(
          (b) => b.id == 'task-card',
        );
        expect(original.blockType, 'task');
        expect(original.resource!.properties, contains('task-fixture'));
        expect(original.text, isEmpty);
        expect(original.segments, isEmpty);
        final before = native.currentBlocks();
        final index = before.indexWhere((b) => b.id == 'task-card');
        before[index] = native.CollabBlock(
          id: original.id,
          blockType: original.blockType,
          text: '',
          checked: false,
          alignment: original.alignment,
          indent: 0,
          segments: [],
          resource: native.CollabResource(
            properties: original.resource!.properties,
            propertyEdits: '{"title":{"value":"手机任务标题"}}',
          ),
        );
        expect(native.applyBlockSnapshot(blocks: before).v1Update, isNotEmpty);
        native.closeDocument();
        final reopened = native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'task-cache',
          databasePath: database,
        );
        final card = reopened.blocks.firstWhere((b) => b.id == 'task-card');
        expect(card.blockType, 'task');
        expect(card.resource!.properties, contains('手机任务标题'));
        expect(card.text, isEmpty);
        expect(
          reopened.blocks.where((b) => b.id == 'task-invalid').single.blockType,
          'unsupported',
        );
      } finally {
        native.closeDocument();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'desktop meeting props cross FRB, field edits and SQLite reopen',
    () async {
      final dir = await Directory.systemTemp.createTemp('meeting-frb-');
      final database = '${dir.path}/updates.sqlite';
      try {
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'meeting-cache',
          databasePath: database,
        );
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-meeting.update',
          ).readAsBytes(),
        );
        expect(native.documentReadOnlyReason(), isNull);
        final blocks = native.currentBlocks();
        final index = blocks.indexWhere((b) => b.id == 'meeting-1');
        final original = blocks[index];
        expect(original.text, isEmpty);
        expect(original.segments, isEmpty);
        expect(blocks.where((b) => b.blockType == 'meeting').length, 2);
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
            propertyEdits: '{"title":{"value":"新的会议标题"}}',
          ),
          blockBackgroundColor: original.blockBackgroundColor,
          blockBorderColor: original.blockBorderColor,
        );
        expect(native.applyBlockSnapshot(blocks: blocks).v1Update, isNotEmpty);
        final properties = native.currentBlocks()[index].resource!.properties;
        expect(properties, contains('新的会议标题'));
        native.closeDocument();
        final restored = native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'meeting-cache',
          databasePath: database,
        );
        expect(restored.blocks[index].resource!.properties, properties);
        expect(restored.blocks[index].text, isEmpty);
        expect(
          restored.blocks.firstWhere((b) => b.id == 'nested-meeting').parentId,
          'meeting-callout',
        );
      } finally {
        native.closeDocument();
        await dir.delete(recursive: true);
      }
    },
  );
}
