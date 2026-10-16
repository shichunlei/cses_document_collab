import 'dart:io';

import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// Returns comparable hierarchy/text/formatting/appearance from borrowed [blocks].
/// Native block wrappers contain list fields whose identity is irrelevant here.
List<Object?> _calloutProjection(List<native.CollabBlock> blocks) => [
  for (final block in blocks)
    [
      block.id,
      block.parentId,
      block.blockType,
      block.text,
      block.segments,
      block.checked,
      block.alignment,
      block.indent,
      block.calloutPrefix,
      block.blockTextColor,
      block.blockBackgroundColor,
      block.blockBorderColor,
    ],
];

/// Verifies callout hierarchy, appearance and subtree deletion through real FRB/SQLite.
void main() {
  final library = File(
    Platform.isMacOS
        ? 'rust/target/debug/libcses_collab_core.dylib'
        : 'rust/target/debug/libcses_collab_core.so',
  );
  setUpAll(() async {
    if (library.existsSync()) {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(library.absolute.path),
      );
    }
  });

  test(
    'callout parent links and appearance cross real FRB and persist to SQLite',
    () async {
      final directory = await Directory.systemTemp.createTemp('callout-frb-');
      try {
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'callout-cache',
          databasePath: '${directory.path}/updates.sqlite',
        );
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-callout.update',
          ).readAsBytes(),
        );
        expect(native.documentReadOnlyReason(), isNull);
        final before = native.currentBlocks();
        final callout = before.firstWhere((b) => b.blockType == 'callout');
        expect(callout.calloutPrefix, '🤪');
        expect(callout.blockTextColor, '#F97316');
        expect(before.where((b) => b.parentId == callout.id).map((b) => b.id), [
          'callout-body',
          'callout-second',
        ]);
        final result = native.applyBlockSnapshot(
          blocks: [
            for (final block in before)
              if (block.id != callout.id)
                block
              else
                native.CollabBlock(
                  id: block.id,
                  blockType: block.blockType,
                  text: block.text,
                  segments: block.segments,
                  checked: block.checked,
                  alignment: block.alignment,
                  indent: block.indent,
                  parentId: block.parentId,
                  calloutPrefix: '🚀',
                  blockTextColor: '#15803D',
                  blockBackgroundColor: '#DFEAFC',
                  blockBorderColor: '#2563EB',
                ),
          ],
        );
        expect(result.v1Update, isNotEmpty);
        native.closeDocument();
        final reopened = native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'callout-cache',
          databasePath: '${directory.path}/updates.sqlite',
        );
        final restored = reopened.blocks.firstWhere((b) => b.id == callout.id);
        expect(restored.calloutPrefix, '🚀');
        expect(restored.blockTextColor, '#15803D');
        expect(restored.blockBackgroundColor, '#DFEAFC');
        expect(restored.blockBorderColor, '#2563EB');
        expect(
          reopened.blocks.firstWhere((b) => b.id == 'callout-body').parentId,
          callout.id,
        );
        expect(
          reopened.blocks.firstWhere((b) => b.id == 'callout-body').text,
          '这是高亮块儿😀',
        );
      } finally {
        native.closeDocument();
        await directory.delete(recursive: true);
      }
    },
    skip: !library.existsSync(),
  );

  test(
    'callout subtree deletion and restoration persist through real FRB/SQLite',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'callout-delete-frb-',
      );
      final path = '${directory.path}/updates.sqlite';
      try {
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'callout-delete',
          databasePath: path,
        );
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-callout.update',
          ).readAsBytes(),
        );
        final before = native.currentBlocks();
        final callout = before.firstWhere(
          (block) => block.blockType == 'callout',
        );
        final subtree = {callout.id};
        for (final block in before) {
          if (subtree.contains(block.parentId)) subtree.add(block.id);
        }
        final remaining = before
            .where((block) => !subtree.contains(block.id))
            .toList();
        final deleted = native.applyBlockSnapshot(blocks: remaining);
        expect(deleted.v1Update, isNotEmpty);
        expect(
          deleted.blocks.any((block) => subtree.contains(block.id)),
          isFalse,
        );
        final restored = native.applyBlockSnapshot(blocks: before);
        expect(restored.v1Update, isNotEmpty);
        expect(_calloutProjection(restored.blocks), _calloutProjection(before));
        native.applyBlockSnapshot(blocks: remaining);
        native.applyBlockSnapshot(blocks: before);
        native.closeDocument();
        final reopened = native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'callout-delete',
          databasePath: path,
        );
        expect(_calloutProjection(reopened.blocks), _calloutProjection(before));
      } finally {
        native.closeDocument();
        await directory.delete(recursive: true);
      }
    },
    skip: !library.existsSync(),
  );
}
