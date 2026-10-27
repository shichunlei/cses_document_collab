import 'dart:io';
import 'package:cses_document_collab/src/editor/collab_formula_sheet.dart';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_links.dart';
import 'package:cses_document_collab/src/model/collab_block_lock.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/controller/collab_controller.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/editor/collaborative_editor_page.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_formula.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cses_document_collab/src/ui/modal/collab_formula_visual.dart';

/// 验证公式独立补丁、身份定位、编辑面板、渲染与插入焦点。
void main() {
  setUpAll(() async {
    const previewFont = String.fromEnvironment('FORMULA_PREVIEW_FONT');
    if (previewFont.isNotEmpty) {
      final font = FontLoader('FormulaPreview')
        ..addFont(File(previewFont).readAsBytes().then(ByteData.sublistView));
      await font.load();
      final icons = FontLoader('packages/lucide_icons_flutter/Lucide')
        ..addFont(
          rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
        );
      await icons.load();
      for (final (family, file) in [
        ('KaTeX_Main', 'KaTeX_Main-Regular'),
        ('KaTeX_Math', 'KaTeX_Math-Italic'),
      ]) {
        final mathFont = FontLoader('packages/flutter_math_fork/$family')
          ..addFont(
            rootBundle.load(
              'packages/flutter_math_fork/lib/katex_fonts/fonts/$file.ttf',
            ),
          );
        await mathFont.load();
      }
    }
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

  testWidgets('card opens unified editing; creation has no block actions', (
    tester,
  ) async {
    final adapter = await _mount(tester);
    expect(find.byKey(const ValueKey('block-more-math')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('collab-formula-math')));
    await tester.pumpAndSettle();
    expect(find.text('编辑公式'), findsOneWidget);
    expect(find.byKey(const ValueKey('formula-insert-below')), findsOneWidget);
    expect(find.byKey(const ValueKey('formula-delete')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('formula-close')));
    await tester.pumpAndSettle();
    final future = showCollabFormulaInput(
      tester.element(find.byType(CollaborativeEditorPage)),
      adapter.editorState,
      creatingBlock: true,
    );
    await tester.pumpAndSettle();
    expect(find.text('新建公式'), findsOneWidget);
    expect(find.text('创建'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('formula-input')),
      'E=mc^2',
    );
    await tester.pumpAndSettle();
    await _captureFormulaPreview(tester, 'create');
    expect(find.byKey(const ValueKey('formula-insert-below')), findsNothing);
    expect(find.byKey(const ValueKey('formula-delete')), findsNothing);
    expect(find.byType(CupertinoSwitch), findsNothing);
    await tester.tap(find.byKey(const ValueKey('formula-close')));
    await tester.pumpAndSettle();
    expect(await future, isNull);
  });

  testWidgets(
    'copy preserves draft; dirty insertion cancels or saves then inserts as independent history',
    (tester) async {
      final adapter = await _mount(tester);
      final state = adapter.editorState;
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final links = CollabParagraphLinks(
        editor: state,
        documentId: 'doc1',
        buildLink: (doc, block) => 'https://example.com/$doc?blockId=$block',
      );
      addTearDown(links.dispose);
      await tester.tap(find.byKey(const ValueKey('collab-formula-math')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('formula-input')),
        'x^3',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('formula-copy-link')),
      );
      await tester.tap(find.byKey(const ValueKey('formula-copy-link')));
      await tester.pumpAndSettle();
      expect(copied.single, 'https://example.com/doc1?blockId=math');
      expect(
        find.byKey(const ValueKey('collab-formula-sheet')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('formula-input')))
            .controller!
            .text,
        'x^3',
      );
      expect(adapter.blocks.first.resource!.string('latex'), 'E=mc^2');
      await tester.ensureVisible(
        find.byKey(const ValueKey('formula-insert-below')),
      );
      await tester.tap(find.byKey(const ValueKey('formula-insert-below')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('formula-draft-cancel')));
      await tester.pumpAndSettle();
      expect(adapter.blocks.length, 2);
      await tester.tap(find.byKey(const ValueKey('formula-insert-below')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('formula-draft-save')));
      await tester.pumpAndSettle();
      expect(adapter.blocks.length, 3);
      expect(adapter.blocks.first.resource!.string('latex'), 'x^3');
      expect(state.selection, Selection.single(path: [1], startOffset: 0));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      state.undoManager.undo();
      await tester.pumpAndSettle();
      expect(adapter.blocks.length, 2);
      expect(adapter.blocks.first.resource!.string('latex'), 'x^3');
      state.undoManager.undo();
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.resource!.string('latex'), 'E=mc^2');
    },
  );

  for (final (owner, inherited, grant, canToggle, template) in [
    ('alice', false, false, true, false),
    ('bob', false, false, false, false),
    ('alice', true, false, false, false),
    ('bob', false, true, true, false),
    ('alice', false, false, false, true),
    ('alice', false, true, true, true),
  ]) {
    testWidgets(
      'locked formula view and unlock permissions $owner/$inherited/$grant/$template',
      (tester) async {
        final adapter = await _mount(tester);
        final state = adapter.editorState;
        late CollabBlockLocks locks;
        var commits = 0;
        locks = CollabBlockLocks(
          editor: state,
          userId: 'alice',
          canUnlock: (_) => grant,
          commit: (id, value, expected) async {
            commits++;
            expect(expected.ownerId, owner);
            expect(value, isFalse);
            locks.update([const CollabBlockLockState(blockId: 'math')]);
          },
        );
        locks.update([
          CollabBlockLockState(
            blockId: 'math',
            sourceId: inherited ? 'parent' : 'math',
            ownerId: owner,
            template: template,
            containsLock: true,
          ),
        ]);
        addTearDown(locks.dispose);
        await tester.tap(find.byKey(const ValueKey('collab-formula-math')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('formula-input')))
              .enabled,
          isFalse,
        );
        expect(find.byKey(const ValueKey('formula-save')), findsNothing);
        expect(find.byKey(const ValueKey('formula-delete')), findsNothing);
        expect(
          find.byKey(const ValueKey('formula-insert-below')),
          findsNothing,
        );
        final toggle = find.byType(CupertinoSwitch);
        expect(tester.widget<CupertinoSwitch>(toggle).onChanged != null, canToggle);
        if (canToggle) {
          await tester.ensureVisible(toggle);
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(commits, 1);
          expect(
            find.byKey(const ValueKey('collab-formula-sheet')),
            findsNothing,
          );
          expect(state.selection, isNull);
        } else {
          if (inherited) expect(find.text('定位上级锁定块'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('formula-close')));
          await tester.pumpAndSettle();
        }
      },
    );
  }

  testWidgets(
    'lock after dirty confirmation invalidates old session even after unlock',
    (tester) async {
      final adapter = await _mount(tester);
      final state = adapter.editorState;
      var commits = 0;
      final locks = CollabBlockLocks(
        editor: state,
        userId: 'alice',
        canUnlock: (_) => false,
        commit: (_, _, _) async {
          commits++;
        },
      );
      locks.update([const CollabBlockLockState(blockId: 'math')]);
      addTearDown(locks.dispose);
      await tester.tap(find.byKey(const ValueKey('collab-formula-math')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('formula-input')),
        'draft',
      );
      await tester.ensureVisible(find.byType(CupertinoSwitch));
      await tester.tap(find.byType(CupertinoSwitch));
      await tester.pumpAndSettle();
      locks.update([
        const CollabBlockLockState(
          blockId: 'math',
          sourceId: 'math',
          ownerId: 'alice',
        ),
      ]);
      locks.update([const CollabBlockLockState(blockId: 'math')]);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('formula-draft-save')));
      await tester.pumpAndSettle();
      expect(commits, 0);
      expect(adapter.blocks.first.resource!.string('latex'), 'E=mc^2');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('formula-save')))
            .onPressed,
        isNull,
      );
      expect(find.text('锁状态或权限已更新，请关闭后重新打开'), findsOneWidget);
    },
  );

  testWidgets(
    'discard draft before insertion; remote change during dismiss prevents stale command',
    (tester) async {
      final adapter = await _mount(tester);
      await tester.tap(find.byKey(const ValueKey('collab-formula-math')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('formula-input')),
        'discarded',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('formula-insert-below')),
      );
      await tester.tap(find.byKey(const ValueKey('formula-insert-below')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('formula-draft-discard')));
      await tester.pumpAndSettle();
      expect(adapter.blocks.length, 3);
      expect(adapter.blocks.first.resource!.string('latex'), 'E=mc^2');
      await tester.tap(find.byKey(const ValueKey('collab-formula-math')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('formula-insert-below')),
      );
      await tester.tap(find.byKey(const ValueKey('formula-insert-below')));
      await tester.pump();
      await adapter.replaceFromRemote([_formula('remote^2'), _tail]);
      await tester.pumpAndSettle();
      expect(adapter.blocks.length, 2);
      expect(adapter.blocks.first.resource!.string('latex'), 'remote^2');
    },
  );

  for (final (save, fail) in [(true, false), (false, false), (true, true)]) {
    testWidgets(
      'dirty lock choice saves=$save failure=$fail executes after dismissal',
      (tester) async {
        final adapter = await _mount(tester);
        final state = adapter.editorState;
        var commits = 0;
        late CollabBlockLocks locks;
        locks = CollabBlockLocks(
          editor: state,
          userId: 'alice',
          canUnlock: (_) => false,
          commit: (id, locked, expected) async {
            expect(
              find.byKey(const ValueKey('collab-formula-sheet')),
              findsNothing,
            );
            commits++;
            if (fail) throw StateError('lock unavailable');
            locks.update([
              CollabBlockLockState(
                blockId: id,
                sourceId: id,
                ownerId: 'alice',
                containsLock: true,
              ),
            ]);
          },
        );
        locks.update([const CollabBlockLockState(blockId: 'math')]);
        addTearDown(locks.dispose);
        await tester.tap(find.byKey(const ValueKey('collab-formula-math')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('formula-input')),
          'saved^2',
        );
        await tester.ensureVisible(find.byType(CupertinoSwitch));
        await tester.tap(find.byType(CupertinoSwitch));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(
            ValueKey(save ? 'formula-draft-save' : 'formula-draft-discard'),
          ),
        );
        await tester.pumpAndSettle();
        expect(commits, 1);
        expect(
          adapter.blocks.first.resource!.string('latex'),
          save ? 'saved^2' : 'E=mc^2',
        );
        expect(state.selection, isNull);
        if (fail) expect(find.text('公式操作失败，请重试'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('deleted target restored with same ID cannot revive old panel', (
    tester,
  ) async {
    final adapter = await _mount(tester);
    await tester.tap(find.byKey(const ValueKey('collab-formula-math')));
    await tester.pumpAndSettle();
    await adapter.replaceFromRemote([_tail]);
    await tester.pumpAndSettle();
    await adapter.replaceFromRemote([_formula('E=mc^2'), _tail]);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('formula-save')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('formula-input')))
          .enabled,
      isFalse,
    );
  });

  for (final (size, scale, keyboard) in [
    (const Size(390, 844), 1.0, 0.0),
    (const Size(320, 568), 1.5, 240.0),
    (const Size(780, 390), 1.0, 130.0),
  ]) {
    testWidgets(
      'unified panel keeps header/actions reachable $size/$scale/$keyboard',
      (tester) async {
        final adapter = await _mount(
          tester,
          size: size,
          scale: scale,
          keyboard: keyboard,
        );
        final state = adapter.editorState;
        final locks = CollabBlockLocks(
          editor: state,
          userId: 'alice',
          canUnlock: (_) => false,
          commit: (_, _, _) async {},
        );
        locks.update([const CollabBlockLockState(blockId: 'math')]);
        final links = CollabParagraphLinks(
          editor: state,
          documentId: 'd1',
          buildLink: (_, _) => 'https://example.com',
        );
        addTearDown(locks.dispose);
        addTearDown(links.dispose);
        await tester.tap(find.byKey(const ValueKey('collab-formula-math')));
        await tester.pumpAndSettle();
        final title = tester.getRect(find.text('编辑公式'));
        final save = tester.getRect(find.byKey(const ValueKey('formula-save')));
        final delete = tester.getRect(
          find.byKey(const ValueKey('formula-delete')),
        );
        expect(save.bottom, lessThanOrEqualTo(size.height - keyboard));
        expect(delete.bottom, lessThanOrEqualTo(size.height - keyboard));
        expect(delete.left, lessThan(save.left));
        expect(delete.overlaps(save), isFalse);
        await tester.ensureVisible(
          find.byKey(const ValueKey('formula-insert-below')),
        );
        await tester.pumpAndSettle();
        expect(tester.getRect(find.text('编辑公式')), title);
        expect(
          tester.getRect(find.byKey(const ValueKey('formula-save'))),
          save,
        );
        expect(
          tester.getRect(find.byKey(const ValueKey('formula-delete'))),
          delete,
        );
        expect(tester.takeException(), isNull);
        if (size.width == 390) await _captureFormulaPreview(tester, 'edit');
      },
    );
  }
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
/// [size]为逻辑视口，[scale]为文字倍率，[keyboard]为键盘逻辑高度，均默认普通手机布局。
/// 测试退出先卸载Widget，再释放页面借用的控制器与编辑器。
Future<AppFlowyBlockEditorAdapter> _mount(
  WidgetTester tester, {
  List<CollabEditorBlock>? blocks,
  Size size = const Size(390, 844),
  double scale = 1,
  double keyboard = 0,
}) async {
  await tester.binding.setSurfaceSize(size);
  final adapter = AppFlowyBlockEditorAdapter(
    initialBlocks: blocks ?? [_formula('E=mc^2'), _tail],
    onLocalBlocksChanged: (_) {},
  );
  final controller = _ReadyController(adapter.editorState);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
    controller.dispose();
    adapter.dispose();
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('formula-preview-boundary'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          fontFamily:
              const String.fromEnvironment('FORMULA_PREVIEW_FONT').isEmpty
              ? null
              : 'FormulaPreview',
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: size,
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: CollaborativeEditorPage(collab: controller),
      ),
    ),
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

/// 可选导出[tester]当前的[name]真实Flutter面板PNG；环境未配置时不访问文件系统。
Future<void> _captureFormulaPreview(WidgetTester tester, String name) async {
  const directory = String.fromEnvironment('FORMULA_PREVIEW_DIR');
  if (directory.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('formula-preview-boundary')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File(
        '$directory/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
