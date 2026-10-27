import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_editing.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_indent.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 使用真实 FRB 和 SQLite 验证段落属性、字体分段和回车数据链路。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final library = File(
      'rust/target/debug/libcses_collab_core.${Platform.isMacOS ? 'dylib' : 'so'}',
    );
    expect(library.existsSync(), isTrue, reason: '先构建本包原生库');
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(library.absolute.path),
    );
  });
  test('FRB empty defaults, typing, body Enter and SQLite reopen', () async {
    final directory = await Directory.systemTemp.createTemp('paragraph-frb-');
    AppFlowyBlockEditorAdapter? adapter;
    try {
      final path = '${directory.path}/updates.sqlite';
      native.openCsesDocument(
        documentId: 'fixture-doc',
        cacheDocumentId: 'paragraph-cache',
        databasePath: path,
      );
      native.applyDocumentUpdate(
        bytes: File(
          'rust/tests/fixtures/blockcraft-basic.update',
        ).readAsBytesSync(),
      );
      final untouched = native.currentBlocks();
      native.applyBlockSnapshot(
        blocks: [
          ...untouched,
          const native.CollabBlock(
            id: 'defaults',
            blockType: 'paragraph',
            text: '',
            segments: [],
            checked: false,
            alignment: 'left',
            indent: 0,
            paragraphStyle: native.CollabResource(
              properties:
                  '{"textDefaults":{"a:bold":true,"t:px":24,"t:ff":"courier"},"nextParagraphStyle":"same"}',
            ),
          ),
        ],
      );
      final source = native.currentBlocks().last;
      adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          CollabEditorBlock(
            id: source.id,
            blockType: source.blockType,
            text: source.text,
            paragraphStyle: CollabResource(
              properties: source.paragraphStyle!.properties,
            ),
          ),
        ],
        onLocalBlocksChanged: (blocks) {
          native.applyBlockSnapshot(
            blocks: [...untouched, ..._nativeBlocks(blocks)],
          );
        },
      );
      final state = adapter.editorState;
      state.selection = Selection.single(path: [0], startOffset: 0);
      expect(state.toggledStyle[AppFlowyRichTextKeys.bold], isTrue);
      expect(state.toggledStyle['t:px'], 24);
      await state.apply(
        state.transaction
          ..insertText(
            state.document.first!,
            0,
            '中文',
            toggledAttributes: state.toggledStyle,
          )
          ..afterSelection = Selection.single(path: [0], startOffset: 2),
      );
      await setCollabNextParagraphStyle(state, 'body');
      await handleCollabParagraphEnter(state);
      final saved = native.currentBlocks();
      expect(saved[saved.length - 2].text, '中文');
      expect(jsonDecode(saved[saved.length - 2].segments.single.typography!), {
        't:ff': 'courier',
        't:px': 24,
      });
      expect(saved.last.text, isEmpty);
      expect(saved.last.blockType, 'paragraph');
      expect(
        jsonDecode(saved.last.paragraphStyle!.properties)['textDefaults'],
        isNull,
      );
      native.closeDocument();
      final restored = native
          .openCsesDocument(
            documentId: 'fixture-doc',
            cacheDocumentId: 'paragraph-cache',
            databasePath: path,
          )
          .blocks;
      expect(
        restored.map(
          (b) => (b.id, b.blockType, b.text, b.paragraphStyle?.properties),
        ),
        saved.map(
          (b) => (b.id, b.blockType, b.text, b.paragraphStyle?.properties),
        ),
      );
      for (var index = 0; index < saved.length; index++) {
        expect(restored[index].segments, saved[index].segments);
      }
      expect(native.documentReadOnlyReason(), isNull);
    } finally {
      adapter?.dispose();
      native.closeDocument();
      await directory.delete(recursive: true);
    }
  });
  test(
    'empty heading resets native defaults, size and depth in the existing paragraph identity',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'empty-heading-frb-',
      );
      AppFlowyBlockEditorAdapter? adapter;
      try {
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'empty-heading',
          databasePath: '${directory.path}/updates.sqlite',
        );
        native.applyDocumentUpdate(
          bytes: File(
            'rust/tests/fixtures/blockcraft-basic.update',
          ).readAsBytesSync(),
        );
        final others = native
            .currentBlocks()
            .where((b) => b.id != 'p2')
            .toList();
        native.applyBlockSnapshot(
          blocks: [
            ...others,
            const native.CollabBlock(
              id: 'p2',
              blockType: 'heading_2',
              text: '',
              segments: [],
              checked: false,
              alignment: 'center',
              indent: 0,
              paragraphStyle: native.CollabResource(
                properties: '{}',
                propertyEdits:
                    '{"textDefaults":{"value":{"a:bold":true}},"fs":{"value":28},"depth":{"value":3}}',
              ),
            ),
          ],
        );
        final heading = native.currentBlocks().last;
        adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: [
            CollabEditorBlock(
              id: heading.id,
              blockType: heading.blockType,
              text: '',
              alignment: heading.alignment,
              paragraphStyle: CollabResource(
                properties: heading.paragraphStyle!.properties,
              ),
            ),
          ],
          onLocalBlocksChanged: (blocks) {
            native.applyBlockSnapshot(
              blocks: [...others, ..._nativeBlocks(blocks)],
            );
          },
        );
        adapter.editorState.selection = Selection.single(
          path: [0],
          startOffset: 0,
        );
        await handleCollabParagraphEnter(adapter.editorState);
        final body = native.currentBlocks().last;
        expect(body.id, 'p2');
        expect(body.blockType, 'paragraph');
        final props = jsonDecode(body.paragraphStyle!.properties) as Map;
        expect(props['textDefaults'], isNull);
        expect(props['fs'], isNull);
        expect(props['depth'], isNull); // 零值由既有 indent 通道表达。
        adapter.editorState.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        final restored = native.currentBlocks().last;
        expect(restored.blockType, 'heading_2');
        expect(jsonDecode(restored.paragraphStyle!.properties)['depth'], 3);
        expect(
          jsonDecode(restored.paragraphStyle!.properties)['textDefaults'],
          {'a:bold': true},
        );
      } finally {
        adapter?.dispose();
        native.closeDocument();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'paragraph Tab depth eight persists through FRB, history and SQLite reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'paragraph-depth-frb-',
      );
      AppFlowyBlockEditorAdapter? adapter;
      try {
        final path = '${directory.path}/updates.sqlite';
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'depth-cache',
          databasePath: path,
        );
        native.applyDocumentUpdate(
          bytes: File(
            'rust/tests/fixtures/blockcraft-basic.update',
          ).readAsBytesSync(),
        );
        final others = native.currentBlocks();
        final blocks = [
          for (final id in ['depth-previous', 'depth-target'])
            CollabEditorBlock(
              id: id,
              blockType: 'heading_3',
              text: '缩进正文',
              paragraphStyle: CollabResource.fromValues({'depth': 7}),
            ),
        ];
        native.applyBlockSnapshot(
          blocks: [...others, ..._nativeBlocks(blocks)],
        );
        adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: blocks,
          onLocalBlocksChanged: (blocks) {
            native.applyBlockSnapshot(
              blocks: [...others, ..._nativeBlocks(blocks)],
            );
          },
        );
        final state = adapter.editorState;
        state.selection = Selection.single(path: [1], startOffset: 1);
        expect(await changeCollabBlockIndent(state, 1), isTrue);
        expect(
          jsonDecode(
            native.currentBlocks().last.paragraphStyle!.properties,
          )['depth'],
          8,
        );
        state.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        expect(
          jsonDecode(
            native.currentBlocks().last.paragraphStyle!.properties,
          )['depth'],
          7,
        );
        state.undoManager.redo();
        await Future<void>.delayed(Duration.zero);
        expect(
          jsonDecode(
            native.currentBlocks().last.paragraphStyle!.properties,
          )['depth'],
          8,
        );
        adapter.dispose();
        adapter = null;
        native.closeDocument();
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'depth-cache',
          databasePath: path,
        );
        expect(
          jsonDecode(
            native.currentBlocks().last.paragraphStyle!.properties,
          )['depth'],
          8,
        );
      } finally {
        adapter?.dispose();
        native.closeDocument();
        await directory.delete(recursive: true);
      }
    },
  );
}

/// 将本用例的段落 [blocks] 映射到真实桥接输入；保留默认格式补丁和全部字符外观。
List<native.CollabBlock> _nativeBlocks(List<CollabEditorBlock> blocks) => [
  for (final block in blocks)
    native.CollabBlock(
      id: block.id,
      blockType: block.blockType,
      text: block.text,
      checked: block.checked,
      alignment: block.alignment,
      indent: block.indent,
      replacesId: block.replacesId,
      paragraphStyle: block.paragraphStyle == null
          ? null
          : native.CollabResource(
              properties: block.paragraphStyle!.properties,
              propertyEdits: block.paragraphStyle!.propertyEdits,
            ),
      segments: [
        for (final s in block.segments)
          native.CollabTextSegment(
            text: s.text,
            href: s.href,
            bold: s.bold,
            italic: s.italic,
            underline: s.underline,
            strikethrough: s.strikethrough,
            code: s.code,
            textColor: s.textColor,
            backgroundColor: s.backgroundColor,
            superscript: s.superscript,
            subscript: s.subscript,
            typography: s.typography,
          ),
      ],
    ),
];
