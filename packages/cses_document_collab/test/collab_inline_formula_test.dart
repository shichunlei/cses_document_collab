import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/controller/collab_controller.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_inline_formula.dart';
import 'package:cses_document_collab/src/editor/collaborative_editor_page.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_inline_formula.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 行内单字符定位、历史隔离、混合正文输入、UI 编辑与远端竞态回归。
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
    'UTF16 projection and independent edit undo resolve block identity after reorder',
    () async {
      final adapter = _adapter();
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      final node = state.document.first!;
      expect(node.delta!.toPlainText(), '前😀\uFFFC后');
      expect(node.delta!.length, 5);
      final target = CollabInlineFormulaTarget.capture(node, 3)!;
      expect(
        await changeCollabInlineFormula(
          state,
          target,
          'y^2',
          expectedLatex: 'x^2',
        ),
        isTrue,
      );
      expect(adapter.blocks.first.segments[1].inlineLatex, 'y^2');
      final blocks = adapter.blocks;
      await adapter.replaceFromRemote([blocks[1], blocks[0]]);
      state.undoManager.undo();
      await pumpEventQueue();
      expect(adapter.blocks.last.segments[1].inlineLatex, 'x^2');
      state.undoManager.redo();
      await pumpEventQueue();
      expect(adapter.blocks.last.segments[1].inlineLatex, 'y^2');
      await adapter.replaceFromRemote([_tail, _mixed(latex: 'remote^2')]);
      state.undoManager.undo();
      await pumpEventQueue();
      expect(adapter.blocks.last.segments[1].inlineLatex, 'remote^2');
      state.editable = false;
      expect(
        await changeCollabInlineFormula(
          state,
          target,
          '',
          expectedLatex: 'remote^2',
        ),
        isFalse,
      );
    },
  );
  test(
    'insert replaces a backward range, undo keeps original styles, adjacent typing is plain',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'body',
            blockType: 'paragraph',
            text: 'ab😀cd',
            segments: [CollabEditorTextSegment(text: 'ab😀cd', bold: true)],
          ),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      final landing = await insertCollabInlineFormula(
        state,
        Selection.single(path: [0], startOffset: 4, endOffset: 2),
        r'\frac{a}{b}',
      );
      expect(landing!.start.offset, 3);
      expect(adapter.blocks.single.text, 'ab\uFFFCcd');
      expect(
        adapter.blocks.single.segments
            .where((s) => s.inlineLatex != null)
            .length,
        1,
      );
      state.undoManager.undo();
      await pumpEventQueue();
      expect(adapter.blocks.single.text, 'ab😀cd');
      expect(adapter.blocks.single.segments.single.bold, isTrue);
      state.undoManager.redo();
      await pumpEventQueue();
      final node = state.document.first!;
      await state.apply(state.transaction..insertText(node, 3, '后插'));
      await state.apply(state.transaction..insertText(node, 2, '前插'));
      expect(adapter.blocks.single.text, 'ab前插\uFFFC后插cd');
      expect(
        adapter.blocks.single.segments
            .where((s) => s.inlineLatex != null)
            .length,
        1,
      );
      final target = CollabInlineFormulaTarget.capture(node, 4)!;
      expect(
        await changeCollabInlineFormula(
          state,
          target,
          '',
          expectedLatex: r'\frac{a}{b}',
        ),
        isTrue,
      );
      expect(adapter.blocks.single.text, 'ab前插后插cd');
    },
  );
  test(
    'identical adjacent formula runs stay two atomic objects and stale positions fail',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'body',
            blockType: 'paragraph',
            text: '\uFFFC\uFFFC',
            segments: [
              CollabEditorTextSegment(text: '\uFFFC', inlineLatex: 'x'),
              CollabEditorTextSegment(text: '\uFFFC', inlineLatex: 'x'),
            ],
          ),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      expect(adapter.blocks.single.segments.length, 2);
      final state = adapter.editorState;
      final target = CollabInlineFormulaTarget.capture(
        state.document.first!,
        1,
      )!;
      await state.apply(
        state.transaction..insertText(state.document.first!, 0, 'shift'),
      );
      expect(target.resolve(state), isNull);
      expect(
        await changeCollabInlineFormula(
          state,
          target,
          'other',
          expectedLatex: 'x',
        ),
        isFalse,
      );
      expect(
        adapter.blocks.single.segments
            .where((s) => s.inlineLatex == 'x')
            .length,
        2,
      );
    },
  );
  test(
    'desktop empty formula deletes one atom; ordinary U+FFFC remains text',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'body',
            blockType: 'paragraph',
            text: '\uFFFC\uFFFC',
            segments: [
              CollabEditorTextSegment(text: '\uFFFC', inlineLatex: ''),
              CollabEditorTextSegment(text: '\uFFFC'),
            ],
          ),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      final target = CollabInlineFormulaTarget.capture(
        state.document.first!,
        0,
      )!;
      expect(
        CollabInlineFormulaTarget.capture(state.document.first!, 1),
        isNull,
      );
      expect(
        await changeCollabInlineFormula(state, target, '', expectedLatex: ''),
        isTrue,
      );
      expect(adapter.blocks.single.text, '\uFFFC');
      expect(adapter.blocks.single.segments, isEmpty);
    },
  );
  testWidgets(
    'mixed paragraph renders formulas inline, saves edits and empty input deletes one',
    (tester) async {
      final adapter = await _mount(tester);
      expect(find.byType(CollabInlineFormula), findsOneWidget);
      final formula = find.byKey(
        const ValueKey('collab-inline-formula-body-3'),
      );
      final oldSelection = Selection.single(path: [0], startOffset: 4);
      adapter.editorState.selection = oldSelection;
      await tester.tap(formula);
      await tester.pumpAndSettle();
      expect(find.text('行内公式'), findsOneWidget);
      expect(adapter.editorState.selection, isNull);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('formula-input')))
            .controller!
            .text,
        'x^2',
      );
      await tester.enterText(
        find.byKey(const ValueKey('formula-input')),
        r'\frac{x}{2}',
      );
      await tester.tap(find.byKey(const ValueKey('formula-save')));
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.segments[1].inlineLatex, r'\frac{x}{2}');
      expect(adapter.blocks.first.text, '前😀\uFFFC后');
      expect(adapter.editorState.selection, oldSelection);
      await tester.tap(formula);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('formula-input')),
        r'\sqrt{625}',
      );
      await tester.tap(find.byKey(const ValueKey('formula-save')));
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.segments[1].inlineLatex, r'\sqrt{625}');
      expect(tester.getSize(formula).width, greaterThan(20));
      expect(tester.getSize(formula).width, lessThan(150));
      await tester.tap(formula);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('formula-input')), '');
      await tester.tap(find.byKey(const ValueKey('formula-save')));
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.text, '前😀后');
      expect(find.byType(CollabInlineFormula), findsNothing);
      adapter.editorState.undoManager.undo();
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.segments[1].inlineLatex, r'\sqrt{625}');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'remote formula conflict reloads; surrounding text changes disable stale editing',
    (tester) async {
      final adapter = await _mount(tester);
      await tester.tap(
        find.byKey(const ValueKey('collab-inline-formula-body-3')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('formula-input')),
        'draft',
      );
      await adapter.replaceFromRemote([_mixed(latex: 'remote^2'), _tail]);
      await tester.pumpAndSettle();
      expect(find.text('公式已由其他设备修改，请重新加载后编辑'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('formula-save')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('formula-reload')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('formula-input')))
            .controller!
            .text,
        'remote^2',
      );
      await adapter.replaceFromRemote([
        _mixed(prefix: '远端前😀', latex: 'remote^2'),
        _tail,
      ]);
      await tester.pumpAndSettle();
      expect(find.text('公式已删除、位置变化或当前不可编辑'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('formula-save')))
            .onPressed,
        isNull,
      );
      expect(adapter.blocks.first.segments[1].inlineLatex, 'remote^2');
      await tester.tap(find.byKey(const ValueKey('formula-close')));
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'long and consecutive formulas fit narrow large-text layout and remain editable',
    (tester) async {
      final latex = List.filled(35, 'x^2').join('+');
      final adapter = await _mount(
        tester,
        blocks: [
          CollabEditorBlock(
            id: 'body',
            blockType: 'paragraph',
            text: 'a\uFFFC\uFFFCb',
            segments: [
              const CollabEditorTextSegment(text: 'a'),
              CollabEditorTextSegment(text: '\uFFFC', inlineLatex: latex),
              CollabEditorTextSegment(text: '\uFFFC', inlineLatex: latex),
              const CollabEditorTextSegment(text: 'b'),
            ],
          ),
        ],
      );
      await tester.binding.setSurfaceSize(const Size(320, 568));
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      expect(find.byType(CollabInlineFormula), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('预览'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('collab-inline-formula-body-1')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('collab-formula-sheet')), findsNothing);
      expect(
        adapter.blocks.single.segments
            .where((s) => s.inlineLatex != null)
            .length,
        2,
      );
    },
  );
  testWidgets(
    'more inserts inside original paragraph and restores one-character caret',
    (tester) async {
      final adapter = await _mount(
        tester,
        blocks: const [
          CollabEditorBlock(id: 'body', blockType: 'paragraph', text: 'AB'),
        ],
      );
      final state = adapter.editorState;
      state.selection = Selection.single(path: [0], startOffset: 1);
      var completed = false;
      final action = showEditorAddBlockSheet(
        tester.element(find.byType(CollaborativeEditorPage)),
        state,
      ).then((_) => completed = true);
      await tester.pumpAndSettle();
      final tile = find.byKey(const ValueKey('editor-shortcut-inline-formula'));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('formula-input')),
        'x^2',
      );
      await tester.tap(find.byKey(const ValueKey('formula-save')));
      await tester.pumpAndSettle();
      for (var i = 0; i < 8 && !completed; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(completed, isTrue);
      await action;
      expect(adapter.blocks.single.text, 'A\uFFFCB');
      expect(state.selection!.start.offset, 2);
      expect(find.byType(CollabInlineFormula), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 150));
    },
  );
}

/// [prefix]/[latex] 构造带 emoji 和一个单字符行内公式的不可变正文样本。
CollabEditorBlock _mixed({String prefix = '前😀', String latex = 'x^2'}) =>
    CollabEditorBlock(
      id: 'body',
      blockType: 'paragraph',
      text: '$prefix\uFFFC后',
      segments: [
        CollabEditorTextSegment(text: prefix),
        CollabEditorTextSegment(text: '\uFFFC', inlineLatex: latex),
        const CollabEditorTextSegment(text: '后'),
      ],
    );

/// 提供独立后置段落用于保存和恢复选区。
const _tail = CollabEditorBlock(
  id: 'tail',
  blockType: 'paragraph',
  text: '后置文字',
);

/// 创建测试持有的适配器，用例负责释放。
AppFlowyBlockEditorAdapter _adapter() => AppFlowyBlockEditorAdapter(
  initialBlocks: [_mixed(), _tail],
  onLocalBlocksChanged: (_) {},
);

/// 在 [tester] 中挂载真实编辑页；[blocks] 默认混合正文与后置段落。
/// 测试退出先卸载 Widget，再释放借用控制器和适配器。
Future<AppFlowyBlockEditorAdapter> _mount(
  WidgetTester tester, {
  List<CollabEditorBlock>? blocks,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  final adapter = AppFlowyBlockEditorAdapter(
    initialBlocks: blocks ?? [_mixed(), _tail],
    onLocalBlocksChanged: (_) {},
  );
  final controller = _ReadyController(adapter.editorState);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 150));
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

/// 借用测试编辑器，不打开原生连接。
class _ReadyController extends CollabController {
  /// [state] 由测试创建和释放，不转移所有权。
  _ReadyController(this.state) : super.localDraft(databasePath: '/unused');

  /// 已创建的借用编辑器。
  final EditorState state;

  /// 返回借用编辑器。
  @override
  EditorState get editorState => state;

  /// 测试已就绪。
  @override
  bool get initialized => true;

  /// 宿主允许编辑，预览状态由页面持有。
  @override
  bool get canEdit => true;
}
