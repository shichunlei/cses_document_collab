import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/editor/collab_callout_block.dart';
import 'package:cses_document_collab/src/editor/collab_page_divider_block.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_page_divider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证根级分页符的插入、展示、历史、远端更新及菜单权限边界。
void main() {
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(0.0),
          ),
        );
  });
  for (final text in ['', '保留正文😀']) {
    test(
      'root insertion preserves text and has independent undo: $text',
      () async {
        final changes = <List<CollabEditorBlock>>[];
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: [
            CollabEditorBlock(id: 'source', blockType: 'paragraph', text: text),
          ],
          onLocalBlocksChanged: changes.add,
        );
        addTearDown(adapter.dispose);
        final state = adapter.editorState;
        final landing = await insertCollabPageDivider(
          state,
          Selection.single(path: [0], startOffset: 0),
        );
        expect(landing!.start.path, text.isEmpty ? [1] : [2]);
        final divider = adapter.blocks.firstWhere(
          (b) => b.blockType == collabPageDividerType,
        );
        expect(divider.id, isNot('source'));
        expect(divider.replacesId, isNull);
        expect(divider.parentId, isNull);
        expect(divider.text, isEmpty);
        expect(divider.segments, isEmpty);
        expect(divider.resource, isNull);
        expect(state.getNodeAtPath(text.isEmpty ? [0] : [1])!.delta, isNull);
        state.undoManager.undo();
        await pumpEventQueue();
        expect(adapter.blocks.single.text, text);
        state.undoManager.redo();
        await pumpEventQueue();
        expect(adapter.blocks.any((b) => b.id == divider.id), isTrue);
        state.selection = landing;
        expect(await deletePreviousUrlBackedBlock(state), isTrue);
        expect(
          adapter.blocks.any((b) => b.blockType == collabPageDividerType),
          isFalse,
        );
        state.undoManager.undo();
        await pumpEventQueue();
        expect(changes.last.any((b) => b.id == divider.id), isTrue);
      },
    );
  }
  test(
    'nested, range, stale, readonly and disposed insertion does not write',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(id: 'box', blockType: 'callout', text: ''),
          CollabEditorBlock(
            id: 'nested',
            parentId: 'box',
            blockType: 'paragraph',
            text: '',
          ),
          CollabEditorBlock(id: 'tail', blockType: 'paragraph', text: '正文'),
        ],
        onLocalBlocksChanged: (_) => fail('invalid insertion published'),
      );
      final state = adapter.editorState;
      for (final selection in [
        Selection.single(path: [0, 0], startOffset: 0),
        Selection.single(path: [1], startOffset: 0, endOffset: 1),
        Selection.single(path: [9], startOffset: 0),
      ]) {
        expect(await insertCollabPageDivider(state, selection), isNull);
      }
      state.editable = false;
      expect(
        await insertCollabPageDivider(
          state,
          Selection.single(path: [1], startOffset: 0),
        ),
        isNull,
      );
      adapter.dispose();
      expect(
        await insertCollabPageDivider(
          state,
          Selection.single(path: [1], startOffset: 0),
        ),
        isNull,
      );
    },
  );
  test(
    'deleting last break leaves editable paragraph and undo/redo restores identity',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [_break],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      expect(await deleteCollabPageDivider(state, 'break'), isTrue);
      expect(adapter.blocks.single.blockType, 'paragraph');
      expect(adapter.blocks.single.id, isNot('break'));
      state.undoManager.undo();
      await pumpEventQueue();
      expect(adapter.blocks.single, _break);
      state.undoManager.redo();
      await pumpEventQueue();
      expect(adapter.blocks.single.blockType, 'paragraph');
      expect(await deleteCollabPageDivider(state, 'break'), isFalse);
    },
  );
  test(
    'remote text patch preserves break node and does not publish local edits',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [_break, _tail],
        onLocalBlocksChanged: (_) => fail('remote patch published'),
      );
      addTearDown(adapter.dispose);
      final source = adapter.editorState.getNodeAtPath([0]);
      await adapter.replaceFromRemote(const [
        _break,
        CollabEditorBlock(id: 'tail', blockType: 'paragraph', text: '远端'),
      ]);
      expect(identical(adapter.editorState.getNodeAtPath([0]), source), isTrue);
      expect(adapter.blocks.first, _break);
      expect(adapter.blocks.last.text, '远端');
    },
  );
  for (final width in [320.0, 390.0]) {
    testWidgets('marker, insertion below, delete menu and preview at $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [_break, _tail],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      await tester.pumpWidget(_app(adapter, scale: 2));
      await tester.pumpAndSettle();
      expect(find.text('分页符'), findsOneWidget);
      expect(find.byTooltip('更多操作'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tapAt(
        tester
                .getRect(
                  find.byKey(const ValueKey('collab-page-divider-break')),
                )
                .centerLeft +
            const Offset(4, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('分页符操作'), findsOneWidget);
      await tester.tap(find.text('在下方插入'));
      await tester.pumpAndSettle();
      expect(adapter.blocks.map((b) => b.blockType), [
        'page-divider',
        'paragraph',
        'paragraph',
      ]);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('collab-page-divider-break')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除分页符'));
      await tester.pumpAndSettle();
      expect(find.text('分页符'), findsNothing);
      adapter.editorState.undoManager.undo();
      await tester.pumpAndSettle();
      expect(find.text('分页符'), findsOneWidget);
      adapter.editorState.editable = false;
      await tester.pumpAndSettle();
      expect(find.byTooltip('更多操作'), findsNothing);
      expect(find.text('分页符'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('collab-page-divider-break')));
      await tester.pumpAndSettle();
      expect(find.text('分页符操作'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  for (final invalidate in ['permission', 'delete', 'reorder']) {
    testWidgets('open menu rejects $invalidate changes', (tester) async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [_break, _tail],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      await tester.pumpWidget(_app(adapter));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('collab-page-divider-break')));
      await tester.pumpAndSettle();
      if (invalidate == 'permission') {
        adapter.editorState.editable = false;
        adapter.editorState.editable = true;
      } else if (invalidate == 'delete') {
        await adapter.replaceFromRemote(const [_tail]);
      } else {
        await adapter.replaceFromRemote(const [_tail, _break]);
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除分页符'));
      await tester.pumpAndSettle();
      // Reorders resolve the current stable target; revocation or deletion invalidates it.
      expect(
        adapter.blocks.any((b) => b.id == 'break'),
        invalidate == 'permission',
      );
      expect(adapter.blocks.last.id, 'tail');
      expect(tester.takeException(), isNull);
    });
  }
  for (final reason in ['nested', 'permission', 'deleted', 'range']) {
    testWidgets('add sheet refuses $reason bookmark', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          if (reason == 'nested')
            const CollabEditorBlock(id: 'box', blockType: 'callout', text: ''),
          CollabEditorBlock(
            id: 'source',
            parentId: reason == 'nested' ? 'box' : null,
            blockType: 'paragraph',
            text: '原正文',
          ),
          _tail,
        ],
        onLocalBlocksChanged: (_) => fail('invalid menu published'),
      );
      addTearDown(adapter.dispose);
      await tester.pumpWidget(_app(adapter));
      await tester.pumpAndSettle();
      adapter.editorState.selection = Selection.single(
        path: reason == 'nested' ? [0, 0] : [0],
        startOffset: 0,
        endOffset: reason == 'range' ? 1 : 0,
      );
      await tester.pumpAndSettle();
      final flow = showEditorAddBlockSheet(
        tester.element(find.byType(AppFlowyEditor)),
        adapter.editorState,
      );
      await tester.pumpAndSettle();
      if (reason == 'permission') {
        adapter.editorState.editable = false;
        adapter.editorState.editable = true;
      } else if (reason == 'deleted') {
        await adapter.replaceFromRemote(const [_tail]);
      }
      final tile = find.byKey(const ValueKey('editor-shortcut-page-divider'));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(adapter.blocks.any((b) => b.blockType == 'page-divider'), isFalse);
      expect(
        find.byKey(const ValueKey('editor-add-block-sheet')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('editor-add-block-close')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await flow;
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('add sheet inserts root break and restores caret', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [
        CollabEditorBlock(id: 'p', blockType: 'paragraph', text: ''),
      ],
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);
    await tester.pumpWidget(_app(adapter, toolbar: true));
    await tester.pumpAndSettle();
    adapter.editorState.selection = Selection.single(path: [0], startOffset: 0);
    await tester.pumpAndSettle();
    final flow = showEditorAddBlockSheet(
      tester.element(find.byType(AppFlowyEditor)),
      adapter.editorState,
    );
    await tester.pumpAndSettle();
    final tile = find.byKey(const ValueKey('editor-shortcut-page-divider'));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(adapter.blocks.first.blockType, collabPageDividerType);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await flow;
    expect(adapter.editorState.selection?.start.path, [1]);
    expect(tester.takeException(), isNull);
  });
}

/// 根级无正文分页符投影。
const _break = CollabEditorBlock(
  id: 'break',
  blockType: 'page-divider',
  text: '',
);

/// 分页符后的普通正文。
const _tail = CollabEditorBlock(
  id: 'tail',
  blockType: 'paragraph',
  text: '后续正文',
);

/// 使用借用的 [adapter] 构建真实编辑器；[scale] 指定文字倍率，默认 1。
/// [toolbar] 为 true 时挂载真实添加面板入口，不接管编辑器生命周期。
Widget _app(
  AppFlowyBlockEditorAdapter adapter, {
  double scale = 1,
  bool toolbar = false,
}) {
  final editor = AppFlowyEditor(
    editorState: adapter.editorState,
    editorStyle: const EditorStyle.mobile(),
    blockComponentBuilders: {
      ...standardBlockComponentBuilderMap,
      'page-divider': CollabPageDividerBlockComponentBuilder(),
      'callout': CollabCalloutBlockComponentBuilder(),
    },
  );
  return MaterialApp(
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      AppFlowyEditorLocalizations.delegate,
    ],
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: toolbar
          ? EditorShortcutToolbar(
              editorState: adapter.editorState,
              child: editor,
            )
          : editor,
    ),
  );
}
