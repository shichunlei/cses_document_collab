import 'dart:io';

import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 使用真实动态库验证行内公式的新桥接字段、单字符定位及 SQLite 重开。
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
    'mixed formulas survive FRB edits and reopen with native Y.Text positions',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'inline-formula-frb-',
      );
      final database = '${directory.path}/updates.sqlite';
      try {
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'inline-formula-cache',
          databasePath: database,
        );
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-inline-formula.update',
          ).readAsBytes(),
        );
        expect(native.documentReadOnlyReason(), isNull);
        final blocks = native.currentBlocks();
        final original = blocks.first;
        expect(original.text, '前😀\uFFFC后\uFFFC\uFFFC\uFFFC');
        expect(original.segments.where((s) => s.inlineLatex != null).length, 3);
        var edited = false;
        final segments = original.segments.map((segment) {
          final latex = !edited && segment.inlineLatex != null
              ? r'\sqrt{625}'
              : segment.inlineLatex;
          if (segment.inlineLatex != null) edited = true;
          return native.CollabTextSegment(
            text: segment.text,
            bold: segment.bold,
            italic: segment.italic,
            underline: segment.underline,
            strikethrough: segment.strikethrough,
            code: segment.code,
            textColor: segment.textColor,
            backgroundColor: segment.backgroundColor,
            superscript: segment.superscript,
            subscript: segment.subscript,
            inlineLatex: latex,
          );
        }).toList();
        blocks[0] = native.CollabBlock(
          id: original.id,
          blockType: original.blockType,
          text: original.text,
          segments: segments,
          checked: original.checked,
          alignment: original.alignment,
          indent: original.indent,
          blockBackgroundColor: original.blockBackgroundColor,
          blockBorderColor: original.blockBorderColor,
        );
        expect(native.applyBlockSnapshot(blocks: blocks).v1Update, isNotEmpty);
        final changed = native.currentBlocks().first;
        expect(changed.text, original.text);
        expect(
          changed.segments.firstWhere((s) => s.inlineLatex != null).inlineLatex,
          r'\sqrt{625}',
        );
        native.closeDocument();
        final restored = native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'inline-formula-cache',
          databasePath: database,
        );
        expect(native.documentReadOnlyReason(), isNull);
        expect(restored.blocks.first.text, changed.text);
        expect(
          restored.blocks.first.segments.map(
            (s) => (s.text, s.inlineLatex, s.bold),
          ),
          changed.segments.map((s) => (s.text, s.inlineLatex, s.bold)),
        );
        expect(restored.blocks.last.parentId, 'inline-callout');
      } finally {
        native.closeDocument();
        await directory.delete(recursive: true);
      }
    },
  );
}
