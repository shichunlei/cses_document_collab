import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/controller/collab_controller.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/editor/collaborative_editor_page.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_formula.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cses_document_collab/src/ui/modal/collab_formula_visual.dart';

/// 验证公式独立补丁、身份定位、编辑面板、渲染与插入焦点。
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
    'field undo preserves missing/null and relocates after remote reorder',
    () async {
      for (final properties in ['{}', '{"latex":null}', '{"latex":""}']) {
        final changes = <List<CollabEditorBlock>>[];
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: [
            CollabEditorBlock(
              id: 'math',
              blockType: 'formula',
              text: '',
              resource: CollabResource(properties: properties),
            ),
            _tail,
          ],
          onLocalBlocksChanged: changes.add,
        );
        final state = adapter.editorState;
        expect(
          await changeCollabFormula(state, 'math', r'\frac{x}{2}'),
          isTrue,
        );
        expect(
          changes.last.first.resource!.propertyEdits,
          '{"latex":{"value":"\\\\frac{x}{2}"}}',
        );
        expect(findCollabFormula(state, 'math')!.delta, isNull);
        final updated = adapter.blocks;
        await adapter.replaceFromRemote([updated[1], updated[0]]);
        changes.clear();
        state.undoManager.undo();
        await pumpEventQueue();
        expect(adapter.blocks.last.resource!.properties, properties);
        expect(
          changes.last.last.resource!.propertyEdits,
          properties == '{}'
              ? '{"latex":{}}'
              : '{"latex":{"value":${properties == '{"latex":null}' ? 'null' : '""'}}}',
        );
        state.undoManager.redo();
        await pumpEventQueue();
        expect(adapter.blocks.last.resource!.string('latex'), r'\frac{x}{2}');
        expect(
          await changeCollabFormula(state, 'math', 'x', expectedField: '{}'),
          isFalse,
        );
        expect(await changeCollabFormula(state, 'math', '😀' * 10001), isFalse);
        state.editable = false;
        expect(await changeCollabFormula(state, 'math', 'x'), isFalse);
        state.editable = true;
        await adapter.replaceFromRemote([_tail]);
        state.undoManager.undo();
        await pumpEventQueue();
        expect(adapter.blocks.length, 1);
        adapter.dispose();
      }
    },
  );

  test(
    'insert empty/nonempty and nested formulas, backspace and undo',
    () async {
      for (final nested in [false, true]) {
        for (final text in ['', '保留正文']) {
          final adapter = AppFlowyBlockEditorAdapter(
            initialBlocks: [
              if (nested)
                const CollabEditorBlock(
                  id: 'box',
                  blockType: 'callout',
                  text: '',
                ),
              CollabEditorBlock(
                id: 'source',
                parentId: nested ? 'box' : null,
                blockType: 'paragraph',
                text: text,
              ),
            ],
            onLocalBlocksChanged: (_) {},
          );
          final state = adapter.editorState;
          final landing = await insertCollabFormula(
            state,
            Selection.single(path: nested ? [0, 0] : [0], startOffset: 0),
            'E=mc^2',
          );
          final formula = adapter.blocks.firstWhere(
            (b) => b.blockType == 'formula',
          );
          expect(formula.id, isNot('source'));
          expect(formula.replacesId, isNull);
          expect(formula.parentId, nested ? 'box' : null);
          expect(formula.text, isEmpty);
          expect(formula.resource!.string('latex'), 'E=mc^2');
          if (text.isNotEmpty) {
            expect(
              adapter.blocks.firstWhere((b) => b.id == 'source').text,
              text,
            );
          }
          state.selection = landing;
          expect(await deletePreviousUrlBackedBlock(state), isTrue);
          expect(adapter.blocks.any((b) => b.blockType == 'formula'), isFalse);
          state.undoManager.undo();
          await pumpEventQueue();
          expect(adapter.blocks.any((b) => b.blockType == 'formula'), isTrue);
          adapter.dispose();
        }
      }
    },
  );

  testWidgets(
    'renders fractions matrices empty and invalid TeX at narrow large text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final latex in [
        '',
        r'\frac{a}{b}+\sqrt{x}',
        r'\begin{pmatrix}1&2\\3&4\end{pmatrix}',
        r'\unknowncommand{',
        List.filled(60, 'x^2').join('+'),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 568),
                textScaler: TextScaler.linear(1.5),
              ),
              child: Scaffold(body: CollabFormulaVisual(latex: latex)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (latex.isEmpty) expect(find.text('添加数学公式'), findsOneWidget);
        if (latex == r'\unknowncommand{') {
          expect(find.text('暂无法渲染此公式'), findsOneWidget);
        }
        if (latex.contains('frac') || latex.contains('pmatrix')) {
          expect(tester.widget<Math>(find.byType(Math)).parseError, isNull);
        }
        if (latex.length > 100) {
          final scrollable = tester.state<ScrollableState>(
            find.byType(Scrollable),
          );
          expect(scrollable.position.maxScrollExtent, greaterThan(0));
          await tester.drag(
            find.byType(SingleChildScrollView),
            const Offset(-150, 0),
          );
          await tester.pumpAndSettle();
          expect(scrollable.position.pixels, greaterThan(0));
        }
      }
    },
  );

  testWidgets(
    'editing preview is local until save; cancel restores selected body',
    (tester) async {
      final adapter = await _mount(tester);
      final state = adapter.editorState;
      final selection = Selection.single(
        path: [1],
        startOffset: 1,
        endOffset: 3,
      );
      state.selection = selection;
      await tester.tap(find.byKey(const ValueKey('collab-formula-math')));
      await tester.pumpAndSettle();
      expect(state.selection, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('formula-input')),
        'a^2+b^2',
      );
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.resource!.string('latex'), 'E=mc^2');
      await tester.tap(find.byKey(const ValueKey('formula-close')));
      await tester.pumpAndSettle();
      expect(state.selection, selection);
      expect(find.byKey(const ValueKey('editor-selection-menu')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('collab-formula-math')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('collab-formula-sheet')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('formula-input')),
        r'\frac{x}{2}',
      );
      await tester.tap(find.byKey(const ValueKey('formula-save')));
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.resource!.string('latex'), r'\frac{x}{2}');
      expect(find.byKey(const ValueKey('collab-formula-sheet')), findsNothing);
      state.undoManager.undo();
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.resource!.string('latex'), 'E=mc^2');
      await tester.tap(find.text('预览'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('collab-formula-math')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('collab-formula-sheet')), findsNothing);
    },
  );

  testWidgets(
    'remote edit conflict reload; permission revoke and deletion disable saving',
    (tester) async {
      final adapter = await _mount(tester);
      await tester.tap(find.byKey(const ValueKey('collab-formula-math')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('formula-input')),
        'draft',
      );
      await adapter.replaceFromRemote([_formula('remote^2'), _tail]);
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
      adapter.editorState.editable = false;
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('formula-save')))
            .onPressed,
        isNull,
      );
      adapter.editorState.editable = true;
      await adapter.replaceFromRemote([_tail]);
      await tester.pumpAndSettle();
      expect(find.text('公式已删除或当前不可编辑'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('formula-save')))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('formula-close')));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'sheet delete last formula leaves editable paragraph and supports undo',
    (tester) async {
      final adapter = await _mount(tester, blocks: [_formula('x')]);
      await tester.tap(find.byKey(const ValueKey('collab-formula-math')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('formula-delete')));
      await tester.pumpAndSettle();
      expect(adapter.blocks.single.blockType, 'paragraph');
      adapter.editorState.undoManager.undo();
      await tester.pumpAndSettle();
      expect(
        adapter.blocks
            .where((b) => b.blockType == 'formula')
            .single
            .resource!
            .string('latex'),
        'x',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow sheet with keyboard and large text keeps close and save accessible',
    (tester) async {
      final adapter = await _mount(tester);
      await tester.binding.setSurfaceSize(const Size(320, 568));
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      addTearDown(() {
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        tester.view.resetViewInsets();
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('collab-formula-math')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('formula-input')),
        r'\begin{pmatrix}1&2\\3&4\end{pmatrix}',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final close = find.byKey(const ValueKey('formula-close'));
      expect(tester.getRect(close).bottom, lessThan(568 - 200));
      await tester.ensureVisible(find.byKey(const ValueKey('formula-save')));
      await tester.tap(find.byKey(const ValueKey('formula-save')));
      await tester.pumpAndSettle();
      expect(
        adapter.blocks.first.resource!.string('latex'),
        contains('pmatrix'),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'nested last formula deletion retains a paragraph inside callout',
    (tester) async {
      final adapter = await _mount(
        tester,
        blocks: [
          const CollabEditorBlock(id: 'box', blockType: 'callout', text: ''),
          CollabEditorBlock(
            id: 'math',
            parentId: 'box',
            blockType: 'formula',
            text: '',
            resource: CollabResource.fromValues({'latex': 'x'}),
          ),
        ],
      );
      await tester.tap(find.byKey(const ValueKey('collab-formula-math')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('formula-delete')));
      await tester.pumpAndSettle();
      expect(adapter.blocks.last.parentId, 'box');
      expect(adapter.blocks.last.blockType, 'paragraph');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'more insert relocates saved block after remote insertion; cancel writes nothing',
    (tester) async {
      final adapter = await _mount(tester, blocks: [_tail]);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [0], startOffset: 2);
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(CollaborativeEditorPage));
      var completed = false;
      final adding = showEditorAddBlockSheet(
        context,
        state,
      ).then((_) => completed = true);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('editor-shortcut-formula')),
      );
      await tester.tap(find.byKey(const ValueKey('editor-shortcut-formula')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('formula-input')),
        'x^2',
      );
      await tester.tap(find.byKey(const ValueKey('formula-close')));
      await tester.pumpAndSettle();
      expect(adapter.blocks.length, 1);
      expect(state.selection, isNull);
      await tester.tap(find.byKey(const ValueKey('editor-shortcut-formula')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('formula-input')),
        'x^2',
      );
      await adapter.replaceFromRemote([
        const CollabEditorBlock(
          id: 'remote',
          blockType: 'paragraph',
          text: '远端',
        ),
        _tail,
      ]);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('formula-save')));
      await tester.pumpAndSettle();
      for (var i = 0; i < 8 && !completed; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(completed, isTrue);
      await adding;
      expect(adapter.blocks.map((b) => b.blockType), [
        'paragraph',
        'paragraph',
        'formula',
        'paragraph',
      ]);
      expect(adapter.blocks[2].resource!.string('latex'), 'x^2');
      expect(state.selection!.start.path, [3]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 150));
    },
  );
}

/// 样本后置正文，提供可恢复的文字选区。
const _tail = CollabEditorBlock(
  id: 'tail',
  blockType: 'paragraph',
  text: '后置正文',
);

/// [latex] 为公式原文，返回具有稳定身份的投影样本。
CollabEditorBlock _formula(String latex) => CollabEditorBlock(
  id: 'math',
  blockType: 'formula',
  text: '',
  resource: CollabResource.fromValues({'latex': latex}),
);

/// 在 [tester] 中挂载真实编辑页面；[blocks] 默认公式与后置正文。
/// 测试退出先卸载 Widget，再释放页面借用的控制器与编辑器。
Future<AppFlowyBlockEditorAdapter> _mount(
  WidgetTester tester, {
  List<CollabEditorBlock>? blocks,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  final adapter = AppFlowyBlockEditorAdapter(
    initialBlocks: blocks ?? [_formula('E=mc^2'), _tail],
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

/// 借用测试编辑器的就绪控制器，不初始化原生连接。
class _ReadyController extends CollabController {
  /// [state] 由测试持有并释放，控制器不接管所有权。
  _ReadyController(this.state) : super.localDraft(databasePath: '/unused');

  /// 借用的已初始化测试编辑器。
  final EditorState state;

  /// 返回借用编辑器。
  @override
  EditorState get editorState => state;

  /// 样本页面已就绪。
  @override
  bool get initialized => true;

  /// 测试宿主授权编辑，预览模式由页面控制。
  @override
  bool get canEdit => true;
}
