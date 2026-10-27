import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/api/collab/history.dart' as history;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 文本框审查缺陷的正式回归，覆盖不透明正文保护、添加边界和预览滚动隔离。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final suffix = Platform.isMacOS ? 'dylib' : 'so';
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(File('rust/target/debug/libcses_collab_core.$suffix').absolute.path),
    );
  });

  test('control: opaque inline at root does not block editing an unrelated root paragraph', () async {
    final dir = await Directory.systemTemp.createTemp('text-box-review-');
    try {
      native.openCsesDocument(
        documentId: 'fixture-doc',
        cacheDocumentId: 'review-cache',
        databasePath: '${dir.path}/updates.sqlite',
      );
      native.applyDocumentUpdate(
        bytes: await File('../../docs/verification/text-box-20261026/review-unknown-inline-root.update').readAsBytes(),
      );
      history.configureDocumentHistory(editable: true);
      final blocks = native.currentBlocks();
      expect(blocks.firstWhere((b) => b.id == 'box-body').blockType, 'unsupported');
      final tail = blocks.firstWhere((b) => b.id == 'tail');
      final next = [
        for (final b in blocks)
          if (b.id == 'tail')
            native.CollabBlock(
              id: b.id,
              blockType: b.blockType,
              text: '${tail.text}手机',
              segments: const [],
              checked: false,
              alignment: 'left',
              indent: 0,
            )
          else
            b,
      ];
      history.applyHistorySnapshot(blocks: next);
      expect(native.currentBlocks().firstWhere((b) => b.id == 'tail').text, '${tail.text}手机');
    } finally {
      native.closeDocument();
      await dir.delete(recursive: true);
    }
  });

  test('opaque inline inside a text-box must not block editing an unrelated root paragraph', () async {
    final dir = await Directory.systemTemp.createTemp('text-box-review-');
    try {
      native.openCsesDocument(
        documentId: 'fixture-doc',
        cacheDocumentId: 'review-cache',
        databasePath: '${dir.path}/updates.sqlite',
      );
      native.applyDocumentUpdate(
        bytes: await File('../../docs/verification/text-box-20261026/review-unknown-inline.update').readAsBytes(),
      );
      history.configureDocumentHistory(editable: true);
      final blocks = native.currentBlocks();
      expect(blocks.firstWhere((b) => b.id == 'box-body').blockType, 'unsupported');
      final tail = blocks.firstWhere((b) => b.id == 'tail');
      final next = [
        for (final b in blocks)
          if (b.id == 'tail')
            native.CollabBlock(
              id: b.id,
              blockType: b.blockType,
              text: '${tail.text}手机',
              segments: const [],
              checked: false,
              alignment: 'left',
              indent: 0,
            )
          else
            b,
      ];
      history.applyHistorySnapshot(blocks: next);
      expect(native.currentBlocks().firstWhere((b) => b.id == 'tail').text, '${tail.text}手机');
    } finally {
      native.closeDocument();
      await dir.delete(recursive: true);
    }
  });

  test('opaque paragraph rejects edits, moves, deletion and forgery without losing history or SQLite data', () async {
    final dir = await Directory.systemTemp.createTemp('text-box-opaque-guards-');
    final database = '${dir.path}/updates.sqlite';
    try {
      native.openCsesDocument(documentId: 'fixture-doc', cacheDocumentId: 'guard-cache', databasePath: database);
      native.applyDocumentUpdate(
        bytes: await File('../../docs/verification/text-box-20261026/review-unknown-inline.update').readAsBytes(),
      );
      history.configureDocumentHistory(editable: true);
      expect(native.documentReadOnlyReason(), isNull);
      final initial = native.currentBlocks();
      final edited = [
        for (final b in initial)
          if (b.id == 'tail')
            native.CollabBlock(
              id: b.id,
              blockType: b.blockType,
              text: '${b.text}已编辑',
              segments: const [],
              checked: false,
              alignment: 'left',
              indent: 0,
            )
          else
            b,
      ];
      history.applyHistorySnapshot(blocks: edited);
      final version = native.encodeStateVector();
      for (var mode = 0; mode < 6; mode++) {
        final invalid = [
          for (final b in native.currentBlocks())
            if (mode == 4 && (b.id == 'text-box' || b.parentId == 'text-box'))
              ...<native.CollabBlock>[]
            else if (b.id != 'box-body')
              b
            else if (mode != 0)
              native.CollabBlock(
                id: mode == 3 ? 'forged-body' : b.id,
                parentId: mode == 1 ? null : b.parentId,
                blockType: mode == 5 ? 'paragraph' : b.blockType,
                text: mode == 2 ? '不能覆盖' : b.text,
                segments: const [],
                checked: false,
                alignment: 'left',
                indent: 0,
              ),
        ];
        expect(() => history.applyHistorySnapshot(blocks: invalid), throwsA(anything), reason: 'mode=$mode');
        expect(native.encodeStateVector(), version);
      }
      expect(history.undoDocument().blocks.firstWhere((b) => b.id == 'tail').text, '后续正文');
      expect(history.redoDocument().blocks.firstWhere((b) => b.id == 'tail').text, '后续正文已编辑');
      final savedVersion = native.encodeStateVector();
      native.closeDocument();
      final reopened = native.openCsesDocument(
        documentId: 'fixture-doc',
        cacheDocumentId: 'guard-cache',
        databasePath: database,
      );
      expect(reopened.blocks.firstWhere((b) => b.id == 'box-body').blockType, 'unsupported');
      expect(reopened.blocks.firstWhere((b) => b.id == 'box-body').parentId, 'text-box');
      expect(reopened.blocks.firstWhere((b) => b.id == 'tail').text, '后续正文已编辑');
      expect(_decodeStateVector(native.encodeStateVector()), _decodeStateVector(savedVersion));
    } finally {
      native.closeDocument();
      await dir.delete(recursive: true);
    }
  });
  for (final text in ['', '正文']) {
    test('empty and nonempty text-box children reject code through both shared commands: $text', () async {
      final adapter = _adapter(text);
      final state = adapter.editorState;
      try {
        final before = state.document.toJson();
        state.selection = Selection.single(path: [0, 0], startOffset: text.length);
        expect(await applyBlockShortcut(state, state.selection!, 'code'), isFalse);
        expect(await applyUrlBlockShortcut(state, state.selection!, 'image', 'https://example.com/image.png'), isNull);
        await applyEditorBlockStyle(state, 'code');
        expect(state.document.toJson(), before);
        expect(state.undoManager.undoStack.isEmpty, isTrue);
      } finally {
        adapter.dispose();
      }
    });
  }
  for (final type in ['paragraph', 'heading', 'quote', 'todo_list', 'bulleted_list', 'numbered_list']) {
    test('valid text-box child $type can be added and independently undone', () async {
      final adapter = _adapter('正文');
      final state = adapter.editorState;
      try {
        final selection = Selection.single(path: [0, 0], startOffset: 2);
        expect(await applyBlockShortcut(state, selection, type, headingLevel: type == 'heading' ? 2 : null), isTrue);
        expect(state.getNodeAtPath([0, 1])!.type, type);
        state.undoManager.undo();
        await pumpEventQueue();
        expect(state.document.root.children.first.children, hasLength(1));
      } finally {
        adapter.dispose();
      }
    });
  }
  test('code remains available outside a text-box', () async {
    final adapter = _adapter('正文');
    try {
      expect(
        await applyBlockShortcut(adapter.editorState, Selection.single(path: [1], startOffset: 4), 'code'),
        isTrue,
      );
      expect(adapter.editorState.getNodeAtPath([2])!.type, 'code');
    } finally {
      adapter.dispose();
    }
  });
  testWidgets('preview must start at the top after editing has scrolled inside a fixed frame', (tester) async {
    final adapter = _adapter(List.generate(30, (i) => '第$i行').join('\n'));
    final preview = ValueNotifier(false);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: preview,
              builder: (context, value, _) => DocumentEditorView(editorState: adapter.editorState, preview: value),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scroll = find
          .descendant(of: find.byKey(const PageStorageKey('text-box-scroll-box')), matching: find.byType(Scrollable))
          .first;
      final state = tester.state<ScrollableState>(scroll);
      state.position.jumpTo(250);
      await tester.pumpAndSettle();
      expect(state.position.pixels, greaterThan(0));
      preview.value = true;
      await tester.pumpAndSettle();
      final next = tester.state<ScrollableState>(
        find
            .descendant(of: find.byKey(const PageStorageKey('text-box-preview-box')), matching: find.byType(Scrollable))
            .first,
      );
      expect(next.position.pixels, 0);
      preview.value = false;
      await tester.pumpAndSettle();
      final restored = tester.state<ScrollableState>(
        find
            .descendant(of: find.byKey(const PageStorageKey('text-box-scroll-box')), matching: find.byType(Scrollable))
            .first,
      );
      expect(restored.position.pixels, 250);
      preview.value = true;
      await tester.pumpAndSettle();
      final secondPreview = tester.state<ScrollableState>(
        find
            .descendant(of: find.byKey(const PageStorageKey('text-box-preview-box')), matching: find.byType(Scrollable))
            .first,
      );
      expect(secondPreview.position.pixels, 0);
    } finally {
      await tester.pumpWidget(const SizedBox());
      preview.dispose();
      adapter.dispose();
    }
  });

  testWidgets('add menu code insertion must not create a forbidden text-box descendant', (tester) async {
    final adapter = _adapter('正文');
    try {
      final state = adapter.editorState;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DocumentEditorView(editorState: state)),
        ),
      );
      await tester.pumpAndSettle();
      state.selection = Selection.single(path: [0, 0], startOffset: 2);
      final applied = await applyBlockShortcut(state, state.selection!, 'code');
      await tester.pumpAndSettle();
      expect(applied, isFalse);
      expect(state.document.root.children.first.children.every((c) => c.type != 'code'), isTrue);
    } finally {
      await tester.pumpWidget(const SizedBox());
      adapter.dispose();
    }
  });
  testWidgets('actual add sheet must keep code out of a text-box', (tester) async {
    final adapter = _adapter('正文');
    Future<void>? opened;
    try {
      final state = adapter.editorState;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DocumentEditorView(editorState: state)),
        ),
      );
      await tester.pumpAndSettle();
      state.selection = Selection.single(path: [0, 0], startOffset: 2);
      opened = showEditorAddBlockSheet(tester.element(find.byType(DocumentEditorView)), state);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-shortcut-code-block')), findsNothing);
      expect(find.byKey(const ValueKey('editor-shortcut-image-block')), findsNothing);
      expect(find.byKey(const ValueKey('editor-shortcut-text-box')), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('editor-shortcut-quote')));
      await tester.tap(find.byKey(const ValueKey('editor-shortcut-quote')));
      await tester.pumpAndSettle();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(state.document.root.children.first.children.map((c) => c.type), ['paragraph', 'quote']);
    } finally {
      await tester.pumpWidget(const SizedBox());
      adapter.dispose();
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      await opened;
    }
  });
}

/// 构造固定高度100的正式文本框，正文[text]由调用方提供，资源均归返回适配器所有。
AppFlowyBlockEditorAdapter _adapter(String text) => AppFlowyBlockEditorAdapter(
  initialBlocks: [
    CollabEditorBlock(
      id: 'box',
      blockType: 'text-box',
      text: '',
      resource: CollabResource.fromValues({'width': 300, 'height': 100}),
    ),
    CollabEditorBlock(id: 'body', parentId: 'box', blockType: 'paragraph', text: text),
    const CollabEditorBlock(id: 'tail', blockType: 'paragraph', text: '框外正文'),
  ],
  onLocalBlocksChanged: (_) {},
);

/// 将原生V1状态向量[bytes]解码为client→clock，比较重开前后的版本而不依赖Map编码顺序。
/// 输入必须是完整的有效V1数据，截断或超长整数抛出FormatException。
Map<int, int> _decodeStateVector(List<int> bytes) {
  var offset = 0;

  /// 读取当前位置的无符号变长整数并推进偏移。
  int read() {
    var value = 0;
    var shift = 0;
    while (offset < bytes.length && shift < 64) {
      final byte = bytes[offset++];
      value |= (byte & 0x7f) << shift;
      if (byte < 0x80) return value;
      shift += 7;
    }
    throw const FormatException('Invalid state vector');
  }

  final count = read();
  return {for (var i = 0; i < count; i++) read(): read()};
}
