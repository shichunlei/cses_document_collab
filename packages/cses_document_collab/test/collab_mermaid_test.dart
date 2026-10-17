import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/controller/collab_controller.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collaborative_editor_page.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_mermaid.dart';
import 'package:cses_document_collab/src/model/collab_mermaid_options.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证父子结构、历史、冲突、权限和正式页面入口；引擎另以真实浏览器验证。
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
  test(
    'shared mode and source save atomically, undo together and reject stale mode',
    () async {
      List<CollabEditorBlock>? published;
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _withMode('graph'),
        onLocalBlocksChanged: (blocks) => published = blocks,
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      final container = findCollabMermaid(state, 'diagram')!;
      final source = collabMermaidSource(container)!;
      final before = jsonEncode(source.delta!.toJson());
      expect(
        await changeCollabMermaid(
          state,
          'diagram',
          'timeline\n2026 : Mobile',
          expectedSourceId: source.id,
          expectedDelta: before,
          view: CollabMermaidView.both,
          expectedModeField: '{"value":"graph"}',
        ),
        isTrue,
      );
      expect(adapter.blocks.first.resource!.string('mode'), 'default');
      expect(
        published!.first.resource!.propertyEdits,
        '{"mode":{"value":"default"}}',
      );
      state.undoManager.undo();
      await pumpEventQueue();
      expect(adapter.blocks.first.resource!.string('mode'), 'graph');
      expect(adapter.blocks[1].text, 'flowchart LR\nA-->B');
      state.undoManager.redo();
      await pumpEventQueue();
      expect(adapter.blocks.first.resource!.string('mode'), 'default');
      expect(
        await changeCollabMermaid(
          state,
          'diagram',
          'stale',
          expectedSourceId: source.id,
          expectedDelta: jsonEncode(source.delta!.toJson()),
          view: CollabMermaidView.text,
          expectedModeField: '{"value":"graph"}',
        ),
        isFalse,
      );
      state.editable = false;
      expect(
        await changeCollabMermaidView(state, 'diagram', CollabMermaidView.text),
        isFalse,
      );
    },
  );

  test(
    'unknown shared modes survive source edits and remote mode invalidates history',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _withMode('future-view'),
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      final source = collabMermaidSource(findCollabMermaid(state, 'diagram'))!;
      expect(
        collabMermaidView(findCollabMermaid(state, 'diagram')!),
        CollabMermaidView.both,
      );
      await changeCollabMermaid(
        state,
        'diagram',
        'flowchart LR\nA-->C',
        expectedSourceId: source.id,
        expectedDelta: jsonEncode(source.delta!.toJson()),
      );
      expect(adapter.blocks.first.resource!.string('mode'), 'future-view');
      await adapter.replaceFromRemote(
        _withMode('text', text: 'flowchart LR\nA-->C'),
      );
      expect(state.undoManager.undoStack.isEmpty, isTrue);
      expect(
        collabMermaidView(findCollabMermaid(state, 'diagram')!),
        CollabMermaidView.text,
      );
    },
  );

  testWidgets(
    'block view switch persists without changing source and follows remote view',
    (tester) async {
      final adapter = await _mount(tester, blocks: _withMode('graph'));
      expect(
        find.byKey(const ValueKey('mermaid-source-view-diagram')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('mermaid-view-diagram')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('仅文本'));
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.resource!.string('mode'), 'text');
      expect(
        find.byKey(const ValueKey('mermaid-source-view-diagram')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('collab-mermaid-visual-diagram')),
        findsNothing,
      );
      expect(adapter.blocks[1].text, 'flowchart LR\nA-->B');
      await adapter.replaceFromRemote(_withMode('default'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mermaid-source-view-diagram')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('collab-mermaid-visual-diagram')),
        findsOneWidget,
      );
      adapter.editorState.editable = false;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mermaid-view-diagram')), findsNothing);
    },
  );

  testWidgets(
    'five templates and type prefixes stay drafts until save, view switching retains source',
    (tester) async {
      final adapter = await _mount(tester, blocks: _withMode('default'));
      await _openSource(tester);
      await tester.pumpAndSettle();
      for (final example in collabMermaidExamples) {
        await tester.tap(find.byKey(const ValueKey('mermaid-template-menu')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(ValueKey('mermaid-template-${example.id}')),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('mermaid-input')))
              .controller!
              .text,
          example.source,
        );
        expect(adapter.blocks[1].text, 'flowchart LR\nA-->B');
      }
      await tester.tap(find.byKey(const ValueKey('mermaid-type-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mermaid-type-sequence')));
      await tester.pumpAndSettle();
      final draft =
          collabMermaidExamples.first.prefix +
          collabMermaidExamples.last.source;
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('mermaid-input')))
            .controller!
            .text,
        draft,
      );
      for (final view in [
        CollabMermaidView.graph,
        CollabMermaidView.text,
        CollabMermaidView.both,
      ]) {
        await tester.tap(
          find.byKey(ValueKey('mermaid-sheet-view-${view.name}')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('mermaid-input')),
          view == CollabMermaidView.graph ? findsNothing : findsOneWidget,
        );
      }
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('mermaid-input')))
            .controller!
            .text,
        draft,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(adapter.blocks[1].text, 'flowchart LR\nA-->B');
    },
  );

  testWidgets(
    'template plus view save is one undo item and remote mode conflicts with open draft',
    (tester) async {
      final adapter = await _mount(tester, blocks: _withMode('default'));
      await _openSource(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mermaid-template-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mermaid-template-class')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mermaid-sheet-view-text')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mermaid-save')));
      await tester.pumpAndSettle();
      expect(adapter.blocks[1].text, collabMermaidExamples[2].source);
      expect(adapter.blocks.first.resource!.string('mode'), 'text');
      adapter.editorState.undoManager.undo();
      await tester.pumpAndSettle();
      expect(adapter.blocks[1].text, 'flowchart LR\nA-->B');
      expect(adapter.blocks.first.resource!.string('mode'), 'default');
      await _openSource(tester);
      await tester.pumpAndSettle();
      await adapter.replaceFromRemote(_withMode('graph'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('mermaid-save')))
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('mermaid-reload')));
      await tester.tap(find.byKey(const ValueKey('mermaid-reload')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mermaid-input')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('mermaid-save')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );

  test('source history, stable identity and stale draft rejection', () async {
    final adapter = _adapter();
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    final source = collabMermaidSource(findCollabMermaid(state, 'diagram'))!;
    final original = jsonEncode(source.delta!.toJson());
    expect(
      await changeCollabMermaid(
        state,
        'diagram',
        'sequenceDiagram\nA->>B: 你好',
        expectedSourceId: source.id,
        expectedDelta: original,
      ),
      isTrue,
    );
    expect(adapter.blocks[1].parentId, 'diagram');
    expect(adapter.blocks[1].id, 'source');
    expect(
      await changeCollabMermaid(
        state,
        'diagram',
        'stale',
        expectedSourceId: source.id,
        expectedDelta: original,
      ),
      isFalse,
    );
    state.undoManager.undo();
    await pumpEventQueue();
    expect(adapter.blocks[1].text, 'flowchart LR\nA-->B');
    state.undoManager.redo();
    await pumpEventQueue();
    expect(adapter.blocks[1].text, contains('你好'));
    state.editable = false;
    expect(
      await changeCollabMermaid(
        state,
        'diagram',
        'readonly',
        expectedSourceId: source.id,
        expectedDelta: jsonEncode(source.delta!.toJson()),
      ),
      isFalse,
    );
  });
  test(
    'remote source update invalidates stale history instead of replaying old offsets',
    () async {
      final adapter = _adapter();
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      final source = collabMermaidSource(findCollabMermaid(state, 'diagram'))!;
      await changeCollabMermaid(
        state,
        'diagram',
        'flowchart LR\nA-->C',
        expectedSourceId: source.id,
        expectedDelta: jsonEncode(source.delta!.toJson()),
      );
      await adapter.replaceFromRemote(_blocks('%% 远端\nflowchart LR\nA-->C'));
      state.undoManager.undo();
      await pumpEventQueue();
      expect(adapter.blocks[1].text, '%% 远端\nflowchart LR\nA-->C');
      expect(state.undoManager.undoStack.isEmpty, isTrue);
      expect(state.undoManager.redoStack.isEmpty, isTrue);
      expect(adapter.blocks.last, _tail);
      state.undoManager.redo();
      await pumpEventQueue();
      expect(adapter.blocks[1].text, '%% 远端\nflowchart LR\nA-->C');
    },
  );
  test(
    'source history after remote reorder never writes another block',
    () async {
      final adapter = _adapter();
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      final source = collabMermaidSource(findCollabMermaid(state, 'diagram'))!;
      await changeCollabMermaid(
        state,
        'diagram',
        'flowchart LR\nA-->C',
        expectedSourceId: source.id,
        expectedDelta: jsonEncode(source.delta!.toJson()),
      );
      final changed = adapter.blocks;
      await adapter.replaceFromRemote([_tail, ...changed.take(2)]);
      state.undoManager.undo();
      await pumpEventQueue();
      expect(adapter.blocks.first, _tail);
      expect(adapter.blocks.last.parentId, 'diagram');
      expect(adapter.blocks.last.blockType, collabMermaidSourceType);
      expect(adapter.blocks.last.text, 'flowchart LR\nA-->C');
    },
  );
  for (final nested in [false, true]) {
    for (final text in ['', '保留正文']) {
      test(
        'insert/delete/history nested=$nested empty=${text.isEmpty}',
        () async {
          final adapter = AppFlowyBlockEditorAdapter(
            initialBlocks: [
              if (nested)
                const CollabEditorBlock(
                  id: 'box',
                  blockType: 'callout',
                  text: '',
                ),
              CollabEditorBlock(
                id: 'anchor',
                parentId: nested ? 'box' : null,
                blockType: 'paragraph',
                text: text,
              ),
            ],
            onLocalBlocksChanged: (_) {},
          );
          addTearDown(adapter.dispose);
          final state = adapter.editorState;
          final original = adapter.blocks;
          expect(
            await insertCollabMermaid(
              state,
              Selection.single(path: nested ? [0, 0] : [0], startOffset: 0),
              collabMermaidTemplate,
            ),
            isNotNull,
          );
          final diagram = adapter.blocks.firstWhere(
            (b) => b.blockType == collabMermaidType,
          );
          final source = adapter.blocks.firstWhere(
            (b) => b.blockType == collabMermaidSourceType,
          );
          expect(source.parentId, diagram.id);
          expect(source.id, isNot(diagram.id));
          expect(diagram.parentId, nested ? 'box' : null);
          expect(source.text, collabMermaidTemplate);
          if (text.isNotEmpty) {
            expect(
              adapter.blocks.any((b) => b.id == 'anchor' && b.text == text),
              isTrue,
            );
          }
          state.undoManager.undo();
          await pumpEventQueue();
          expect(adapter.blocks, original);
          state.undoManager.redo();
          await pumpEventQueue();
          await deleteCollabMermaid(state, diagram.id);
          expect(
            adapter.blocks.any((b) => b.blockType == collabMermaidSourceType),
            isFalse,
          );
          state.undoManager.undo();
          await pumpEventQueue();
          expect(
            adapter.blocks.firstWhere((b) => b.id == source.id).text,
            collabMermaidTemplate,
          );
        },
      );
    }
  }
  test(
    'remote source/reorder/removal retains tree without local publications',
    () async {
      var local = 0;
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _blocks(),
        onLocalBlocksChanged: (_) => local++,
      );
      addTearDown(adapter.dispose);
      await adapter.replaceFromRemote([
        _tail,
        ..._blocks('flowchart TD\n远端-->更新').take(2),
      ]);
      expect(adapter.blocks.map((b) => b.id), ['tail', 'diagram', 'source']);
      expect(
        collabMermaidSource(
          findCollabMermaid(adapter.editorState, 'diagram'),
        )!.delta!.toPlainText(),
        contains('远端'),
      );
      expect(local, 0);
      await adapter.replaceFromRemote([_tail]);
      expect(findCollabMermaid(adapter.editorState, 'diagram'), isNull);
      expect(local, 0);
    },
  );
  test(
    'last deletion supplements paragraph; UTF16 limit rejects writes',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _blocks().take(2).toList(),
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      final source = collabMermaidSource(findCollabMermaid(state, 'diagram'))!;
      expect(
        await changeCollabMermaid(
          state,
          'diagram',
          '😀' * 50001,
          expectedSourceId: source.id,
          expectedDelta: jsonEncode(source.delta!.toJson()),
        ),
        isFalse,
      );
      await deleteCollabMermaid(state, 'diagram');
      expect(adapter.blocks.single.blockType, 'paragraph');
      state.undoManager.undo();
      await pumpEventQueue();
      expect(adapter.blocks.map((b) => b.id), ['diagram', 'source']);
    },
  );
  testWidgets('page edit/cancel/save and undo', (tester) async {
    final adapter = await _mount(tester);
    await _openSource(tester);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('mermaid-input')),
      'flowchart TD\nA-->C',
    );
    expect(adapter.blocks[1].text, 'flowchart LR\nA-->B');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(adapter.blocks[1].text, 'flowchart LR\nA-->B');
    await _openSource(tester);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('mermaid-input')),
      'flowchart TD\nA-->C',
    );
    await tester.tap(find.byKey(const ValueKey('mermaid-save')));
    await tester.pumpAndSettle();
    expect(adapter.blocks[1].text, 'flowchart TD\nA-->C');
    adapter.editorState.undoManager.undo();
    await tester.pumpAndSettle();
    expect(adapter.blocks[1].text, 'flowchart LR\nA-->B');
    expect(tester.takeException(), isNull);
  });
  testWidgets('remote conflict reload and permission revoke invalidate draft', (
    tester,
  ) async {
    final adapter = await _mount(tester);
    await _openSource(tester);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('mermaid-input')),
      'draft',
    );
    await adapter.replaceFromRemote(_blocks('flowchart TD\n远端-->更新'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('mermaid-save')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('mermaid-input')))
          .controller!
          .text,
      'draft',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('mermaid-reload')));
    await tester.tap(find.byKey(const ValueKey('mermaid-reload')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('mermaid-input')))
          .controller!
          .text,
      contains('远端'),
    );
    adapter.editorState.editable = false;
    await tester.pumpAndSettle();
    adapter.editorState.editable = true;
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('mermaid-save')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('keyboard/large text at 320px keeps confirmation visible', (
    tester,
  ) async {
    await _mount(tester);
    tester.view.devicePixelRatio = 1;
    await tester.binding.setSurfaceSize(const Size(320, 568));
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    addTearDown(() {
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      tester.view.resetViewInsets();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpAndSettle();
    await _openSource(tester);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byKey(const ValueKey('mermaid-save'))).bottom,
      lessThanOrEqualTo(368),
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });
  testWidgets('insertion bookmark survives remote reorder', (tester) async {
    final adapter = await _mount(tester, blocks: [_tail]);
    final state = adapter.editorState;
    state.selection = Selection.single(path: [0], startOffset: 1);
    await tester.pumpAndSettle();
    var completed = false;
    final adding = showEditorAddBlockSheet(
      tester.element(find.byType(CollaborativeEditorPage)),
      state,
    ).then((_) => completed = true);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('editor-shortcut-mermaid')),
    );
    await tester.tap(find.byKey(const ValueKey('editor-shortcut-mermaid')));
    await tester.pumpAndSettle();
    await adapter.replaceFromRemote([
      const CollabEditorBlock(id: 'new', blockType: 'paragraph', text: '新段'),
      _tail,
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mermaid-save')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 8 && !completed; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(completed, isTrue);
    await adding;
    expect(adapter.blocks[1].id, 'tail');
    expect(adapter.blocks[2].blockType, collabMermaidType);
    expect(adapter.blocks[3].parentId, adapter.blocks[2].id);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));
  });
}

/// 后置正文样本。
const _tail = CollabEditorBlock(
  id: 'tail',
  blockType: 'paragraph',
  text: '保留正文',
);

/// 从 [text] 构造正式父子块样本。
List<CollabEditorBlock> _blocks([String text = 'flowchart LR\nA-->B']) => [
  const CollabEditorBlock(
    id: 'diagram',
    blockType: collabMermaidType,
    text: '',
  ),
  CollabEditorBlock(
    id: 'source',
    parentId: 'diagram',
    blockType: collabMermaidSourceType,
    text: text,
  ),
  _tail,
];

/// 创建由测试释放的适配器。
AppFlowyBlockEditorAdapter _adapter() => AppFlowyBlockEditorAdapter(
  initialBlocks: _blocks(),
  onLocalBlocksChanged: (_) {},
);

/// 在 [tester] 中挂载页面；[blocks] 默认绘图，先卸载组件再释放借用资源。
Future<AppFlowyBlockEditorAdapter> _mount(
  WidgetTester tester, {
  List<CollabEditorBlock>? blocks,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  final adapter = AppFlowyBlockEditorAdapter(
    initialBlocks: blocks ?? _blocks(),
    onLocalBlocksChanged: (_) {},
  );
  final controller = _ReadyController(adapter.editorState);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));
    controller.dispose();
    adapter.dispose();
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    MaterialApp(home: CollaborativeEditorPage(collab: controller)),
  );
  await tester.pumpAndSettle();
  return adapter;
}

/// 借用测试编辑器，不创建连接。
class _ReadyController extends CollabController {
  /// [state] 由测试创建及释放。
  _ReadyController(this.state) : super.localDraft(databasePath: '/unused');

  /// 必需的借用编辑器。
  final EditorState state;

  /// 返回借用编辑器。
  @override
  EditorState get editorState => state;

  /// 测试页面已就绪。
  @override
  bool get initialized => true;

  /// 测试页面已授权。
  @override
  bool get canEdit => true;
}

/// 为 [mode] 构建共享视图样本；[text] 是唯一源码子块内容。
List<CollabEditorBlock> _withMode(
  String mode, {
  String text = 'flowchart LR\nA-->B',
}) => [
  CollabEditorBlock(
    id: 'diagram',
    blockType: collabMermaidType,
    text: '',
    resource: CollabResource.fromValues({'mode': mode}),
  ),
  CollabEditorBlock(
    id: 'source',
    parentId: 'diagram',
    blockType: collabMermaidSourceType,
    text: text,
  ),
  _tail,
];

/// 在借用[tester]中经统一标题栏更多菜单打开源码，等待菜单退场后再编辑。
Future<void> _openSource(WidgetTester tester) async {
  expect(find.byKey(const ValueKey('mermaid-edit-diagram')), findsNothing);
  await tester.tap(find.byKey(const ValueKey('block-more-diagram')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('mermaid-edit-diagram')));
}
