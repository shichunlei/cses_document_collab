import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:cses_mobile_collab_demo/src/rust/api/collab.dart' as native;
import 'package:cses_mobile_collab_demo/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 使用 cargo build 产出的宿主库验证真实 FRB ABI、正式根/缓存键隔离和 SQLite 恢复。
/// 没有宿主原生库时显式跳过；运行前执行 cargo build --manifest-path rust/Cargo.toml。
void main() {
  final libraryPath = Platform.isMacOS
      ? 'rust/target/debug/libcses_collab_core.dylib'
      : 'rust/target/debug/libcses_collab_core.so';
  final available = File(libraryPath).existsSync();
  setUpAll(() async {
    if (available) {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(File(libraryPath).absolute.path),
      );
    }
  });
  test(
    'ordered replacements, deletion and undo cross FRB with native metadata',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'blockcraft-ordered-frb-',
      );
      AppFlowyBlockEditorAdapter? adapter;
      try {
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'ordered-cache',
          databasePath: '${directory.path}/updates.sqlite',
        );
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-basic.update',
          ).readAsBytes(),
        );
        native.applyBlockSnapshot(
          blocks: native.currentBlocks().take(1).toList(),
        );
        final changes = <native.BlockChangeResult>[];
        adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: [
            CollabEditorBlock(
              id: 'p1',
              blockType: 'paragraph',
              text: native.currentBlocks().single.text,
            ),
          ],
          onLocalBlocksChanged: (blocks) {
            changes.add(
              native.applyBlockSnapshot(
                blocks: blocks
                    .map(
                      (b) => native.CollabBlock(
                        id: b.id,
                        blockType: b.blockType,
                        text: b.text,
                        segments: const [],
                        checked: b.checked,
                        alignment: b.alignment,
                        indent: b.indent,
                        replacesId: b.replacesId,
                      ),
                    )
                    .toList(),
              ),
            );
          },
        );
        final state = adapter.editorState;
        await state.formatNode(
          Selection.single(path: [0], startOffset: 0),
          (n) => n.copyWith(type: NumberedListBlockKeys.type),
        );
        final first = changes.last.blocks.single;
        expect(first.id, isNot('p1'));
        expect(first.ordered?.order, 0);
        // 接收原生身份确认但不进入本地历史，随后 Undo/Redo 必须替换当前原生身份。
        await adapter.replaceFromRemote([
          CollabEditorBlock(
            id: first.id,
            blockType: first.blockType,
            text: first.text,
          ),
        ]);
        state.undoManager.undo();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(native.currentBlocks().single.blockType, 'paragraph');
        final undone = native.currentBlocks().single;
        await adapter.replaceFromRemote([
          CollabEditorBlock(
            id: undone.id,
            blockType: undone.blockType,
            text: undone.text,
          ),
        ]);
        state.undoManager.redo();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(native.currentBlocks().single.blockType, 'numbered_list');
        final one = native.currentBlocks().single;
        final three = [
          one,
          for (final id in ['ordered-two', 'ordered-three'])
            native.CollabBlock(
              id: id,
              blockType: 'numbered_list',
              text: id,
              segments: const [],
              checked: false,
              alignment: 'left',
              indent: 0,
            ),
        ];
        final result = native.applyBlockSnapshot(blocks: three);
        expect(result.blocks.map((b) => b.ordered?.order), [0, 1, 2]);
        final output =
            Platform.environment['CSES_BLOCKCRAFT_ORDERED_INTEROP_OUTPUT'];
        if (output != null) {
          await File(
            output,
          ).writeAsBytes(native.encodeDocumentDiff(stateVector: [0]));
        }
        final afterDelete = native.applyBlockSnapshot(
          blocks: [result.blocks.first, result.blocks.last],
        );
        expect(afterDelete.blocks.map((b) => b.ordered?.order), [0, 1]);
        if (output != null) {
          await File(
            '$output.deleted',
          ).writeAsBytes(native.encodeDocumentDiff(stateVector: [0]));
        }
        native.closeDocument();
        final restored = native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'ordered-cache',
          databasePath: '${directory.path}/updates.sqlite',
        );
        expect(restored.blocks.map((b) => b.ordered?.order), [0, 1]);
      } finally {
        adapter?.dispose();
        native.closeDocument();
        await directory.delete(recursive: true);
      }
    },
    skip: available ? false : '先构建宿主 Rust 库',
  );
  test(
    'desktop ordered fixture survives reorder and depth changes across FRB',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'blockcraft-ordered-boundaries-',
      );
      try {
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'ordered-boundaries',
          databasePath: '${directory.path}/updates.sqlite',
        );
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-ordered.update',
          ).readAsBytes(),
        );
        final blocks = native.currentBlocks();
        expect(blocks[2].ordered?.markerStyle, isNull);
        final first = blocks[0];
        blocks[0] = blocks[2];
        blocks[2] = first;
        final d = blocks[4];
        blocks[4] = native.CollabBlock(
          id: d.id,
          blockType: d.blockType,
          text: d.text,
          segments: d.segments,
          checked: d.checked,
          alignment: d.alignment,
          indent: 0,
          ordered: d.ordered,
        );
        final result = native.applyBlockSnapshot(blocks: blocks);
        expect(
          result.blocks
              .where((b) => b.ordered != null)
              .map((b) => b.ordered!.order),
          [0, 1, 0, 2, 3, 4, 5, 0, 1, 0],
        );
        expect(result.blocks[4].ordered?.markerStyle, isNull);
        final output =
            Platform.environment['CSES_BLOCKCRAFT_ORDERED_INTEROP_OUTPUT'];
        if (output != null) {
          await File(
            '$output.boundaries',
          ).writeAsBytes(native.encodeDocumentDiff(stateVector: [0]));
        }
      } finally {
        native.closeDocument();
        await directory.delete(recursive: true);
      }
    },
    skip: available ? false : '先构建宿主 Rust 库',
  );

  test(
    'formal root survives FRB edits and reopening a different cache identity',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'blockcraft-frb-',
      );
      final databasePath = '${directory.path}/updates.sqlite';
      try {
        final opened = native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'hashed-cache-key',
          databasePath: databasePath,
        );
        expect(opened.sharedTypeName, 'blocks');
        expect(native.documentReadOnlyReason(), isNotNull);
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-basic.update',
          ).readAsBytes(),
        );
        expect(native.documentReadOnlyReason(), isNull);
        final blocks = native.currentBlocks();
        expect(blocks.map((block) => block.id), ['p1', 'p2', 'todo']);
        expect(blocks.first.segments.first.bold, isTrue);
        final old = blocks[1];
        blocks[1] = native.CollabBlock(
          id: old.id,
          blockType: old.blockType,
          text: '${old.text}手机',
          segments: const [],
          checked: old.checked,
          alignment: old.alignment,
          indent: old.indent,
        );
        final changed = native.applyBlockSnapshot(blocks: blocks);
        expect(changed.v1Update, isNotEmpty);
        expect(changed.blocks[1].text, '标题手机');
        final output = Platform.environment['CSES_BLOCKCRAFT_INTEROP_OUTPUT'];
        if (output != null) {
          await File(
            output,
          ).writeAsBytes(native.encodeDocumentDiff(stateVector: [0]));
        }
        native.closeDocument();
        final restored = native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'hashed-cache-key',
          databasePath: databasePath,
        );
        expect(restored.blocks[1].text, '标题手机');
        expect(restored.persistedUpdateCount, greaterThanOrEqualTo(2));
        expect(native.documentReadOnlyReason(), isNull);
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-unknown.update',
          ).readAsBytes(),
        );
        expect(native.documentReadOnlyReason(), isNotNull);
        expect(
          native.currentBlocks().any((block) => block.id == 'cell'),
          isTrue,
        );
        expect(
          () => native.applyBlockSnapshot(blocks: native.currentBlocks()),
          throwsA(anything),
        );
      } finally {
        native.closeDocument();
        await directory.delete(recursive: true);
      }
    },
    skip: available ? false : '先构建宿主 Rust 库',
  );
  test(
    'formal image caption and layout cross FRB and SQLite without flattening',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'blockcraft-image-frb-',
      );
      try {
        final databasePath = '${directory.path}/updates.sqlite';
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'image-cache',
          databasePath: databasePath,
        );
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-image.update',
          ).readAsBytes(),
        );
        expect(native.documentReadOnlyReason(), isNull);
        final blocks = native.currentBlocks();
        final old = blocks.last;
        expect(old.image!.captions.single.id, 'caption-1');
        blocks[blocks.length - 1] = native.CollabBlock(
          id: old.id,
          blockType: old.blockType,
          text: 'https://example.test/mobile.png',
          segments: old.segments,
          checked: old.checked,
          alignment: 'center',
          indent: old.indent,
          image: native.CollabImage(
            widthRatio: 45,
            aspectRatio: old.image!.aspectRatio,
            width: old.image!.width,
            height: old.image!.height,
            rotation: old.image!.rotation,
            captions: [
              const native.CollabImageCaption(
                id: 'caption-1',
                text: '图片题注😀手机',
              ),
            ],
          ),
        );
        final updated = native.applyBlockSnapshot(blocks: blocks);
        expect(updated.blocks.last.image!.widthRatio, 45);
        expect(updated.blocks.last.image!.captions.single.text, '图片题注😀手机');
        final output =
            Platform.environment['CSES_BLOCKCRAFT_IMAGE_INTEROP_OUTPUT'];
        if (output != null) {
          await File(
            output,
          ).writeAsBytes(native.encodeDocumentDiff(stateVector: [0]));
        }
        native.closeDocument();
        final restored = native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'image-cache',
          databasePath: databasePath,
        );
        expect(restored.blocks.last.image!.captions.single.text, '图片题注😀手机');
        expect(restored.blocks.length, 4);
        expect(restored.blocks.last.image!.rotation, 15);
      } finally {
        native.closeDocument();
        await directory.delete(recursive: true);
      }
    },
    skip: available ? false : '先构建宿主 Rust 库',
  );
}
