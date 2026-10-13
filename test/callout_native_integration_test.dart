import 'dart:io';

import 'package:cses_mobile_collab_demo/src/rust/api/collab.dart' as native;
import 'package:cses_mobile_collab_demo/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
