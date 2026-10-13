import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/collab/collab_code.dart';
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
    'six resource schemas cross FRB, update metadata and recover from SQLite',
    () async {
      final directory = await Directory.systemTemp.createTemp('resources-frb-');
      try {
        final databasePath = '${directory.path}/updates.sqlite';
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'resource-cache',
          databasePath: databasePath,
        );
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-resources.update',
          ).readAsBytes(),
        );
        expect(native.documentReadOnlyReason(), isNull);
        final blocks = native.currentBlocks();
        expect(blocks.skip(3).map((b) => b.blockType), [
          'attachment',
          'audio',
          'bookmark',
          'embed',
          'juejin-embed',
          'figma-embed',
        ]);
        expect(blocks.skip(3).every((b) => b.resource != null), isTrue);
        final file = blocks[3];
        blocks[3] = native.CollabBlock(
          id: file.id,
          blockType: file.blockType,
          text: 'https://example.test/new.pdf',
          segments: file.segments,
          checked: file.checked,
          alignment: file.alignment,
          indent: file.indent,
          resource: native.CollabResource(
            properties: file.resource!.properties,
            propertyEdits:
                '{"name":{"value":"新方案.pdf"},"url":{"value":"https://example.test/new.pdf"}}',
          ),
        );
        expect(native.applyBlockSnapshot(blocks: blocks).v1Update, isNotEmpty);
        expect(
          native.currentBlocks()[3].resource!.properties,
          contains('新方案.pdf'),
        );
        native.closeDocument();
        final restored = native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'resource-cache',
          databasePath: databasePath,
        );
        expect(restored.blocks[3].text, 'https://example.test/new.pdf');
        expect(restored.blocks[3].resource!.properties, contains('新方案.pdf'));
        expect(
          restored.blocks.skip(3).every((b) => b.resource != null),
          isTrue,
        );
      } finally {
        native.closeDocument();
        await directory.delete(recursive: true);
      }
    },
    skip: available ? false : '先构建宿主 Rust 库',
  );

  test(
    'desktop video url crosses FRB while unsupported videos stay opaque',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'video-schema-frb-',
      );
      try {
        final databasePath = '${directory.path}/updates.sqlite';
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'video-cache',
          databasePath: databasePath,
        );
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-video.update',
          ).readAsBytes(),
        );
        expect(native.documentReadOnlyReason(), isNull);
        final blocks = native.currentBlocks();
        final video = blocks.firstWhere((b) => b.id == 'video-1');
        expect(video.blockType, csesVideoBlockType);
        expect(video.text, 'https://example.test/video.mp4');
        expect(
          blocks
              .where((b) => b.blockType == csesUnsupportedBlockType)
              .map((b) => b.id),
          ['empty-video', 'embed-video'],
        );
        blocks[blocks.indexOf(video)] = native.CollabBlock(
          id: video.id,
          blockType: video.blockType,
          text: 'https://example.test/replaced.mp4',
          segments: video.segments,
          checked: video.checked,
          alignment: video.alignment,
          indent: video.indent,
        );
        expect(native.applyBlockSnapshot(blocks: blocks).v1Update, isNotEmpty);
        native.closeDocument();
        final restored = native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'video-cache',
          databasePath: databasePath,
        );
        expect(
          restored.blocks.firstWhere((b) => b.id == 'video-1').text,
          'https://example.test/replaced.mp4',
        );
        expect(
          restored.blocks.where((b) => b.blockType == csesUnsupportedBlockType),
          hasLength(2),
        );
      } finally {
        native.closeDocument();
        await directory.delete(recursive: true);
      }
    },
    skip: available ? false : '先构建宿主 Rust 库',
  );

  test(
    'code headers cross FRB, survive body edits and SQLite restore',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'code-header-frb-',
      );
      AppFlowyBlockEditorAdapter? adapter;
      try {
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'code-cache',
          databasePath: '${directory.path}/updates.sqlite',
        );
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-code.update',
          ).readAsBytes(),
        );
        final before = native.currentBlocks();
        final code = before.last;
        expect(code.code!.language, 'Dart');
        expect(code.code!.name, '这是一段dart代码');
        adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: [
            CollabEditorBlock(
              id: code.id,
              blockType: code.blockType,
              text: code.text,
              code: CollabCode(
                language: code.code!.language,
                name: code.code!.name,
                collapsed: code.code!.collapsed,
                rawProperties: code.code!.properties,
              ),
            ),
          ],
          onLocalBlocksChanged: (blocks) {
            final value = blocks.single;
            native.applyBlockSnapshot(
              blocks: [
                ...before.take(before.length - 1),
                native.CollabBlock(
                  id: value.id,
                  blockType: value.blockType,
                  text: value.text,
                  segments: const [],
                  checked: false,
                  alignment: 'left',
                  indent: 0,
                  code: value.code == null
                      ? null
                      : native.CollabCode(
                          language: value.code!.language,
                          name: value.code!.name,
                          collapsed: value.code!.collapsed,
                          properties: value.code!.properties,
                          propertyEdits: value.code!.propertyEdits,
                        ),
                ),
              ],
            );
          },
        );
        final node = adapter.editorState.document.first!;
        await adapter.editorState.apply(
          adapter.editorState.transaction
            ..insertText(node, code.text.length, '// mobile'),
        );
        expect(native.currentBlocks().last.text, '${code.text}// mobile');
        expect(native.currentBlocks().last.code!.language, 'Dart');
        await changeCollabCodeProperty(
          adapter.editorState,
          code.id,
          'blockName',
          '手机名称',
        );
        await changeCollabCodeProperty(
          adapter.editorState,
          code.id,
          'lang',
          'Python',
        );
        await changeCollabCodeProperty(
          adapter.editorState,
          code.id,
          'collapse',
          true,
        );
        expect(native.currentBlocks().last.code!.collapsed, isTrue);
        adapter.editorState.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        expect(native.currentBlocks().last.code!.collapsed, isFalse);
        expect(native.currentBlocks().last.code!.language, 'Python');
        adapter.editorState.undoManager.redo();
        await Future<void>.delayed(Duration.zero);
        native.closeDocument();
        final restored = native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'code-cache',
          databasePath: '${directory.path}/updates.sqlite',
        );
        expect(restored.blocks.last.code!.name, '手机名称');
        expect(restored.blocks.last.code!.language, 'Python');
        expect(restored.blocks.last.code!.collapsed, isTrue);
        expect(restored.blocks.last.text, '${code.text}// mobile');
      } finally {
        adapter?.dispose();
        native.closeDocument();
        await directory.delete(recursive: true);
      }
    },
    skip: !available,
  );

  test('block colors cross FRB and persist in formal props', () async {
    final directory = await Directory.systemTemp.createTemp(
      'block-colors-frb-',
    );
    try {
      native.openCsesDocument(
        documentId: 'fixture-doc',
        cacheDocumentId: 'color-cache',
        databasePath: '${directory.path}/updates.sqlite',
      );
      native.applyDocumentUpdate(
        bytes: await File(
          'rust/tests/fixtures/blockcraft-basic.update',
        ).readAsBytes(),
      );
      final before = native.currentBlocks();
      final block = before.first;
      final result = native.applyBlockSnapshot(
        blocks: [
          native.CollabBlock(
            id: block.id,
            blockType: block.blockType,
            text: block.text,
            segments: block.segments,
            checked: block.checked,
            alignment: block.alignment,
            indent: block.indent,
            blockBackgroundColor: '#ffecdf',
            blockBorderColor: '#f00',
          ),
          ...before.skip(1),
        ],
      );
      expect(result.blocks.first.blockBackgroundColor, '#ffecdf');
      expect(result.blocks.first.blockBorderColor, '#f00');
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          CollabEditorBlock(
            id: block.id,
            blockType: block.blockType,
            text: block.text,
            blockBackgroundColor: result.blocks.first.blockBackgroundColor,
            blockBorderColor: result.blocks.first.blockBorderColor,
          ),
        ],
        onLocalBlocksChanged: (_) {},
      );
      expect(adapter.blocks.single.blockBackgroundColor, '#ffecdf');
      expect(
        adapter
            .editorState
            .document
            .first!
            .attributes[blockComponentBackgroundColor],
        '0xffffecdf',
      );
      adapter.dispose();
      native.closeDocument();
      final restored = native.openCsesDocument(
        documentId: 'fixture-doc',
        cacheDocumentId: 'color-cache',
        databasePath: '${directory.path}/updates.sqlite',
      );
      expect(restored.blocks.first.blockBorderColor, '#f00');
      expect(restored.blocks.first.blockBackgroundColor, '#ffecdf');
    } finally {
      native.closeDocument();
      await directory.delete(recursive: true);
    }
  }, skip: !available);

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
        expect(native.documentReadOnlyReason(), isNull);
        final withPlaceholder = native.currentBlocks();
        expect(withPlaceholder.any((block) => block.id == 'cell'), isFalse);
        expect(withPlaceholder.last.blockType, csesUnsupportedBlockType);
        expect(withPlaceholder.last.text, isEmpty);
        final textBlock = withPlaceholder.firstWhere((b) => b.id == 'p2');
        withPlaceholder[withPlaceholder.indexOf(
          textBlock,
        )] = native.CollabBlock(
          id: textBlock.id,
          blockType: textBlock.blockType,
          text: '${textBlock.text}继续编辑',
          segments: const [],
          checked: textBlock.checked,
          alignment: textBlock.alignment,
          indent: textBlock.indent,
        );
        expect(
          native.applyBlockSnapshot(blocks: withPlaceholder).v1Update,
          isNotEmpty,
        );
        expect(
          native.currentBlocks().firstWhere((b) => b.id == 'p2').text,
          '${textBlock.text}继续编辑',
        );
        native.closeDocument();
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'hashed-cache-key',
          databasePath: databasePath,
        );
        expect(native.documentReadOnlyReason(), isNull);
        expect(native.currentBlocks().last.blockType, csesUnsupportedBlockType);
        expect(
          native.currentBlocks().firstWhere((b) => b.id == 'p2').text,
          '${textBlock.text}继续编辑',
        );
        expect(
          () => native.applyBlockSnapshot(
            blocks: withPlaceholder.take(withPlaceholder.length - 1).toList(),
          ),
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
