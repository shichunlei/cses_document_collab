import 'dart:io';
import 'dart:convert';

import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实FRB/Y.Text和SQLite恢复，不将模拟模型当成原生验证。
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
  test('desktop user atoms insert/delete and reopen across real FRB', () async {
    final directory = await Directory.systemTemp.createTemp('mention-frb-');
    final database = '${directory.path}/updates.sqlite';
    try {
      native.openCsesDocument(
        documentId: 'fixture-doc',
        cacheDocumentId: 'mention-cache',
        databasePath: database,
      );
      native.applyDocumentUpdate(
        bytes: await File(
          'rust/tests/fixtures/blockcraft-user-mention.update',
        ).readAsBytes(),
      );
      expect(native.documentReadOnlyReason(), isNull);
      final blocks = native.currentBlocks();
      final original = blocks.first;
      final user = original.segments.firstWhere((s) => s.mentionId == 'u1');
      expect(jsonDecode(user.mentionAttributes!)['customInline'], 'user');
      final legacy = original.segments.firstWhere((s) => s.mentionId == 'u2');
      expect(jsonDecode(legacy.mentionAttributes!)['d:mentionId'], 'u2');
      expect(original.text, '前😀\uFFFC\uFFFC\uFFFC\uFFFC后');
      expect(
        original.segments
            .where((s) => s.inlineMention != null)
            .map((s) => s.mentionId),
        ['u1', 'u2'],
      );
      final inserted = native.CollabTextSegment(
        text: '\uFFFC',
        bold: false,
        italic: false,
        underline: false,
        strikethrough: false,
        code: false,
        superscript: false,
        subscript: false,
        inlineMention: '李四',
        mentionId: 'u4',
      );
      final segments = [...original.segments]..insert(1, inserted);
      blocks[0] = _replace(original, segments);
      expect(native.applyBlockSnapshot(blocks: blocks).v1Update, isNotEmpty);
      expect(
        native
            .currentBlocks()
            .first
            .segments
            .where((s) => s.inlineMention != null)
            .map((s) => s.mentionId),
        ['u4', 'u1', 'u2'],
      );
      blocks[0] = original;
      expect(native.applyBlockSnapshot(blocks: blocks).v1Update, isNotEmpty);
      expect(native.currentBlocks().first.segments, original.segments);
      native.closeDocument();
      final restored = native.openCsesDocument(
        documentId: 'fixture-doc',
        cacheDocumentId: 'mention-cache',
        databasePath: database,
      );
      expect(native.documentReadOnlyReason(), isNull);
      expect(restored.blocks.first.segments, original.segments);
      expect(restored.blocks.last.parentId, 'mention-callout');
    } finally {
      native.closeDocument();
      await directory.delete(recursive: true);
    }
  });
}

/// 用 [segments] 替换借用 [block] 的正文，保留其他已支持属性。
native.CollabBlock _replace(
  native.CollabBlock block,
  List<native.CollabTextSegment> segments,
) => native.CollabBlock(
  id: block.id,
  blockType: block.blockType,
  text: segments.map((s) => s.text).join(),
  segments: segments,
  checked: block.checked,
  alignment: block.alignment,
  indent: block.indent,
  blockBackgroundColor: block.blockBackgroundColor,
  blockBorderColor: block.blockBorderColor,
);
