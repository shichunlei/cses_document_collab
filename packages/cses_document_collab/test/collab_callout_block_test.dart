import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/controller/collab_controller.dart';
import 'package:cses_document_collab/src/editor/collab_callout_block.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/editor/collaborative_editor_page.dart';
import 'package:cses_document_collab/src/editor/collab_list_editing.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixture = [
  CollabEditorBlock(
    id: 'callout',
    blockType: csesCalloutBlockType,
    text: '',
    calloutPrefix: '🤪',
    blockBackgroundColor: '#F6E5F0',
    blockBorderColor: '#FFE6CD',
    blockTextColor: '#F97316',
  ),
  CollabEditorBlock(
    id: 'body',
    parentId: 'callout',
    blockType: 'paragraph',
    text: '这是高亮块儿',
  ),
  CollabEditorBlock(
    id: 'second',
    parentId: 'callout',
    blockType: 'paragraph',
    text: '第二段',
  ),
  CollabEditorBlock(id: 'tail', blockType: 'paragraph', text: '块外正文'),
];

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

  for (final shape in ['withTail', 'only', 'empty', 'nested']) {
    testWidgets('callout more deletes $shape subtree as one undo step', (
      tester,
    ) async {
      final blocks = [
        if (shape == 'nested')
          const CollabEditorBlock(id: 'outer', blockType: 'callout', text: ''),
        CollabEditorBlock(
          id: 'callout',
          parentId: shape == 'nested' ? 'outer' : null,
          blockType: 'callout',
          text: '',
          calloutPrefix: '💡',
          blockBackgroundColor: '#F6E5F0',
          blockBorderColor: '#FFE6CD',
        ),
        if (shape != 'empty') ...[
          const CollabEditorBlock(
            id: 'body',
            parentId: 'callout',
            blockType: 'paragraph',
            text: '第一段',
            segments: [CollabEditorTextSegment(text: '第一段', bold: true)],
          ),
          const CollabEditorBlock(
            id: 'second',
            parentId: 'callout',
            blockType: 'paragraph',
            text: '第二段',
          ),
        ],
        if (shape == 'withTail') _fixtureTail,
      ];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: blocks,
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      await _pump(tester, adapter);
      final state = adapter.editorState;
      final snapshot = state.document.root.toJson();
      await _openCalloutMenu(tester);
      expect(find.text('颜色设置'), findsOneWidget);
      expect(find.text('在下方插入'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('callout-delete-callout')));
      await tester.pumpAndSettle();
      expect(
        adapter.blocks.any((b) => b.id == 'callout' || b.parentId == 'callout'),
        isFalse,
      );
      expect(state.undoManager.undoStack.isNonEmpty, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);
      if (shape == 'withTail') {
        expect(adapter.blocks, [_fixtureTail]);
      } else {
        expect(adapter.blocks.last.blockType, 'paragraph');
        expect(adapter.blocks.last.text, isEmpty);
        expect(adapter.blocks.last.id, isNot('callout'));
        expect(
          adapter.blocks.last.parentId,
          shape == 'nested' ? 'outer' : null,
        );
      }
      state.undoManager.undo();
      await tester.pumpAndSettle();
      expect(state.document.root.toJson(), snapshot);
      expect(adapter.blocks.length, blocks.length);
      state.undoManager.redo();
      await tester.pumpAndSettle();
      expect(
        adapter.blocks.any((b) => b.id == 'callout' || b.parentId == 'callout'),
        isFalse,
      );
      state.undoManager.undo();
      await tester.pumpAndSettle();
      expect(state.document.root.toJson(), snapshot);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final mutation in [
    'readonly',
    'revokeRestore',
    'child',
    'delete',
    'reorder',
    'session',
  ]) {
    testWidgets('open callout delete menu handles $mutation safely', (
      tester,
    ) async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _fixture,
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      await _pump(tester, adapter);
      await _openCalloutMenu(tester);
      if (mutation == 'readonly' || mutation == 'revokeRestore') {
        adapter.editorState.editable = false;
        if (mutation == 'revokeRestore') adapter.editorState.editable = true;
      } else if (mutation == 'session') {
        final owner = Object();
        CollabRuntime.acquire(
          owner,
          CollabHostServices(onError: (_, _, _, _) {}),
        );
        addTearDown(() => CollabRuntime.release(owner));
      } else if (mutation == 'reorder') {
        await adapter.replaceFromRemote([_fixtureTail, ..._fixture.take(3)]);
      } else if (mutation == 'delete') {
        await adapter.replaceFromRemote([_fixtureTail]);
      } else {
        await adapter.replaceFromRemote([
          _fixture.first,
          const CollabEditorBlock(
            id: 'body',
            parentId: 'callout',
            blockType: 'paragraph',
            text: '远端新正文',
          ),
          ..._fixture.skip(2),
        ]);
      }
      await tester.tap(find.byKey(const ValueKey('callout-delete-callout')));
      await tester.pumpAndSettle();
      if (mutation == 'reorder' || mutation == 'delete') {
        expect(adapter.blocks, [_fixtureTail]);
      } else {
        expect(adapter.blocks.any((b) => b.id == 'callout'), isTrue);
        if (mutation == 'child') expect(adapter.blocks[1].text, '远端新正文');
      }
      expect(
        adapter.editorState.undoManager.undoStack.isEmpty,
        mutation != 'reorder',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('opaque child hides callout deletion and preserves content', (
    tester,
  ) async {
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: [
        _fixture.first,
        const CollabEditorBlock(
          id: 'unknown',
          parentId: 'callout',
          blockType: csesUnsupportedBlockType,
          text: 'graph TD;A-->B',
        ),
        _fixtureTail,
      ],
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);
    await _pump(tester, adapter);
    final snapshot = adapter.editorState.document.root.toJson();
    await _openCalloutMenu(tester);
    expect(find.byKey(const ValueKey('callout-delete-callout')), findsNothing);
    expect(find.text('颜色设置'), findsOneWidget);
    expect(find.text('在下方插入'), findsOneWidget);
    expect(adapter.editorState.document.root.toJson(), snapshot);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'undo deletion leaves the preceding color change independently undoable',
    (tester) async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _fixture.take(3).toList(),
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      await _pump(tester, adapter);
      final state = adapter.editorState;
      await updateCollabCalloutAppearance(
        state,
        'callout',
        csesCalloutPrefixAttribute,
        '💡',
      );
      await tester.pumpAndSettle();
      await _openCalloutMenu(tester);
      await tester.tap(find.byKey(const ValueKey('callout-delete-callout')));
      await tester.pumpAndSettle();
      state.undoManager.undo();
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.calloutPrefix, '💡');
      state.undoManager.undo();
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.calloutPrefix, '🤪');
      expect(adapter.blocks[1].text, _fixture[1].text);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'desktop callout renders nested paragraphs and appearance in edit and preview',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _fixture,
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      await _pump(tester, adapter);
      expect(adapter.editorState.document.root.children.length, 2);
      expect(
        adapter.editorState.getNodeAtPath([0, 0])!.delta!.toPlainText(),
        '这是高亮块儿',
      );
      expect(adapter.blocks, _fixture);
      expect(find.text('🤪'), findsOneWidget);
      final containers = tester.widgetList<Container>(find.byType(Container));
      expect(
        containers.any(
          (widget) =>
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).color ==
                  const Color(0xFFF6E5F0).withValues(alpha: .82) &&
              (widget.decoration as BoxDecoration).border ==
                  Border.all(color: const Color(0xFFFFE6CD)),
        ),
        isTrue,
      );
      final rich = tester
          .widgetList<RichText>(find.byType(RichText))
          .where((w) => w.text.toPlainText().contains('这是高亮块儿'))
          .first;
      bool hasColor(InlineSpan span) =>
          span.style?.color == const Color(0xFFF97316) ||
          (span is TextSpan && (span.children ?? []).any(hasColor));
      expect(hasColor(rich.text), isTrue);
      expect(changes, isEmpty);
      await tester.tap(find.byKey(const ValueKey('editor-mode-toggle')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('collab-callout-settings')),
        findsNothing,
      );
      expect(find.text('🤪'), findsOneWidget);
      expect(adapter.blocks, _fixture);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'shared appearance picker preserves custom colors and independent undo',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'custom',
            blockType: 'callout',
            text: '',
            calloutPrefix: '👩🏽‍💻',
            blockTextColor: '#123456',
            blockBackgroundColor: 'rgba(10, 20, 30, .25)',
            blockBorderColor: '#ABCDEF80',
          ),
          CollabEditorBlock(
            id: 'body',
            parentId: 'custom',
            blockType: 'paragraph',
            text: '已有正文',
          ),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      await _pump(tester, adapter);
      final original = adapter.blocks.first;
      await tester.tap(find.byKey(const ValueKey('block-more-custom')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('collab-callout-settings')));
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
      expect(find.byKey(const ValueKey('callout-text-custom')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('callout-background-custom')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('callout-border-custom')),
        findsOneWidget,
      );
      final border = find.byKey(const ValueKey('callout-border-blue'));
      await tester.ensureVisible(border);
      await tester.pumpAndSettle();
      await tester.tap(border);
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.blockBorderColor, '#DDEBF1');
      expect(adapter.blocks.first.blockTextColor, original.blockTextColor);
      expect(
        adapter.blocks.first.blockBackgroundColor,
        original.blockBackgroundColor,
      );
      expect(adapter.blocks.first.calloutPrefix, '👩🏽‍💻');
      adapter.editorState.undoManager.undo();
      await tester.pumpAndSettle();
      expect(adapter.blocks.first, original);
      expect(adapter.blocks.last.text, '已有正文');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'emoji and color controls publish field edits and independent undo',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _fixture,
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      await _pump(tester, adapter);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [0, 0], startOffset: 2);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('collab-callout-prefix')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('callout-emoji-settings-panel')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('callout-background-blue')),
        findsNothing,
      );
      expect(find.text('文字颜色'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('callout-emoji-💡')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('callout-emoji-settings-panel')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('collab-callout-settings')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('block-more-callout')));
      await tester.pumpAndSettle();
      expect(find.text('在下方插入'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('collab-callout-settings')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('callout-color-settings-panel')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('callout-custom-prefix')), findsNothing);
      expect(find.byKey(const ValueKey('callout-emoji-💡')), findsNothing);
      expect(find.text('文字颜色'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('callout-background-blue')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('callout-color-settings-panel')),
        findsOneWidget,
      );
      final border = find.byKey(const ValueKey('callout-border-green'));
      await tester.ensureVisible(border);
      await tester.tap(border);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('callout-color-settings-panel')),
        findsOneWidget,
      );
      expect(adapter.blocks.first.calloutPrefix, '💡');
      expect(adapter.blocks.first.blockBackgroundColor, '#DDEBF1');
      expect(adapter.blocks.first.blockBorderColor, '#DDEDEA');
      expect(adapter.blocks[1].parentId, 'callout');
      expect(adapter.blocks[1].text, '这是高亮块儿');
      expect(changes.length, 3);
      state.undoManager.undo();
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.blockBorderColor, '#FFE6CD');
      expect(adapter.blocks.first.blockBackgroundColor, '#DDEBF1');
      state.undoManager.redo();
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.blockBorderColor, '#DDEDEA');
      expect(tester.takeException(), isNull);
      Navigator.of(
        tester.element(
          find.byKey(const ValueKey('callout-color-settings-panel')),
        ),
      ).pop();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('footer removes emoji and preserves independent undo', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final changes = <List<CollabEditorBlock>>[];
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: _fixture,
      onLocalBlocksChanged: changes.add,
    );
    addTearDown(adapter.dispose);
    await _pump(tester, adapter);
    await tester.tap(find.byKey(const ValueKey('collab-callout-prefix')));
    await tester.pumpAndSettle();

    final remove = find.byKey(const ValueKey('callout-emoji-clear'));
    final done = find.widgetWithText(TextButton, '完成');
    expect(remove, findsOneWidget);
    expect(tester.getCenter(remove).dy, tester.getCenter(done).dy);
    expect(tester.getRect(remove).right, lessThan(tester.getRect(done).left));
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('callout-emoji-settings-panel')),
      findsNothing,
    );
    expect(adapter.blocks.first.calloutPrefix, '');
    expect(adapter.blocks.skip(1), _fixture.skip(1));
    expect(changes, hasLength(1));
    adapter.editorState.undoManager.undo();
    await tester.pumpAndSettle();
    expect(adapter.blocks, _fixture);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'remote appearance keeps child identity and caret; undo follows reordered callout',
    (tester) async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _fixture,
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      await _pump(tester, adapter);
      final state = adapter.editorState;
      final child = state.getNodeAtPath([0, 0]);
      final caret = Selection.single(path: [0, 0], startOffset: 2);
      state.selection = caret;
      await updateCollabCalloutAppearance(
        state,
        'callout',
        csesCalloutPrefixAttribute,
        '💡',
      );
      const remoteCallout = CollabEditorBlock(
        id: 'callout',
        blockType: csesCalloutBlockType,
        text: '',
        calloutPrefix: '💡',
        blockBackgroundColor: '#DFEAFC',
        blockBorderColor: '#FFE6CD',
        blockTextColor: '#F97316',
      );
      await adapter.replaceFromRemote([remoteCallout, ..._fixture.skip(1)]);
      await tester.pumpAndSettle();
      expect(identical(state.getNodeAtPath([0, 0]), child), isTrue);
      expect(state.selection, caret);
      await adapter.replaceFromRemote(const [
        _fixtureTail,
        remoteCallout,
        CollabEditorBlock(
          id: 'body',
          parentId: 'callout',
          blockType: 'paragraph',
          text: '远端更新正文',
        ),
        CollabEditorBlock(
          id: 'second',
          parentId: 'callout',
          blockType: 'paragraph',
          text: '第二段',
        ),
      ]);
      state.undoManager.undo();
      await tester.pumpAndSettle();
      expect(adapter.blocks[1].calloutPrefix, '🤪');
      expect(adapter.blocks[1].blockBackgroundColor, '#DFEAFC');
      expect(adapter.blocks[2].text, '远端更新正文');
      expect(adapter.blocks.first.text, '块外正文');
      state.editable = false;
      await updateCollabCalloutAppearance(
        state,
        'callout',
        csesCalloutPrefixAttribute,
        '🚀',
      );
      expect(adapter.blocks[1].calloutPrefix, '🤪');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'add sheet inserts a callout and body shortcuts never replace the container',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _fixture,
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      await _pump(tester, adapter);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [0, 0], startOffset: 1);
      final sheet = showEditorAddBlockSheet(
        tester.element(find.byType(AppFlowyEditor)),
        state,
      );
      await tester.pumpAndSettle();
      final tile = find.byKey(const ValueKey('editor-shortcut-callout'));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await sheet;
      expect(state.document.root.children.map((n) => n.type), [
        csesCalloutBlockType,
        csesCalloutBlockType,
        'paragraph',
      ]);
      expect(state.selection!.start.path, [1, 0]);
      // Convert the empty body rather than its parent callout.
      expect(
        await applyBlockShortcut(
          state,
          state.selection!,
          NumberedListBlockKeys.type,
        ),
        isTrue,
      );
      expect(state.getNodeAtPath([1])!.type, csesCalloutBlockType);
      expect(state.getNodeAtPath([1, 0])!.type, NumberedListBlockKeys.type);
      state.selection = Selection.single(path: [1, 0], startOffset: 0);
      expect(await changeCollabListIndent(state, 1), isTrue);
      expect(
        state.getNodeAtPath([1, 0])!.attributes[csesBlockIndentAttribute],
        1,
      );
      final body = state.getNodeAtPath([1, 0])!;
      await state.apply(state.transaction..insertText(body, 0, '列表正文'));
      state.selection = Selection.single(path: [1, 0], startOffset: 4);
      expect(await handleCollabListEnter(state), isTrue);
      expect(state.getNodeAtPath([1])!.children.length, 2);
      expect(
        state.getNodeAtPath([1, 1])!.attributes[csesBlockIndentAttribute],
        1,
      );
      expect(
        adapter.blocks.where(
          (b) =>
              b.parentId ==
              adapter.blocks
                  .firstWhere(
                    (b) =>
                        b.id != 'callout' &&
                        b.blockType == csesCalloutBlockType,
                  )
                  .id,
        ),
        hasLength(2),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'insertion, nested Enter and boundary Backspace preserve container',
    (tester) async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(id: 'p', blockType: 'paragraph', text: '正文'),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      await _pump(tester, adapter);
      final state = adapter.editorState;
      await insertCollabCallout(
        state,
        Selection.single(path: [0], startOffset: 1),
      );
      await tester.pumpAndSettle();
      expect(adapter.blocks[1].blockType, csesCalloutBlockType);
      expect(adapter.blocks[2].parentId, adapter.blocks[1].id);
      expect(state.selection!.start.path, [1, 0]);
      final child = state.getNodeAtPath([1, 0])!;
      await state.apply(state.transaction..insertText(child, 0, '新增正文'));
      state.selection = Selection.single(path: [1, 0], startOffset: 2);
      await state.insertNewLine();
      await tester.pumpAndSettle();
      expect(state.getNodeAtPath([1])!.children.length, 2);
      expect(
        adapter.blocks.skip(2).every((b) => b.parentId == adapter.blocks[1].id),
        isTrue,
      );
      state.selection = Selection.single(path: [1, 0], startOffset: 0);
      expect(
        collabBlockBackspaceCommand.execute(state),
        KeyEventResult.handled,
      );
      await tester.pumpAndSettle();
      expect(state.getNodeAtPath([1])!.type, csesCalloutBlockType);
      expect(state.getNodeAtPath([0])!.delta!.toPlainText(), '正文');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

/// Opens the stable callout's more menu with borrowed [tester].
Future<void> _openCalloutMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('block-more-callout')));
  await tester.pumpAndSettle();
}

const _fixtureTail = CollabEditorBlock(
  id: 'tail',
  blockType: 'paragraph',
  text: '块外正文',
);

Future<void> _pump(
  WidgetTester tester,
  AppFlowyBlockEditorAdapter adapter,
) async {
  final collab = _ReadyController(adapter.editorState);
  addTearDown(collab.dispose);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        AppFlowyEditorLocalizations.delegate,
      ],
      home: CollaborativeEditorPage(collab: collab),
    ),
  );
  await tester.pumpAndSettle();
}

class _ReadyController extends CollabController {
  _ReadyController(this.state) : super.localDraft(databasePath: '/unused');
  final EditorState state;
  @override
  EditorState get editorState => state;
  @override
  bool get initialized => true;
  @override
  bool get canEdit => true;
}
