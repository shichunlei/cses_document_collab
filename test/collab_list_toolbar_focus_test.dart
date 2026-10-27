import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_image.dart';
import 'package:cses_document_collab/src/model/collab_ordered.dart';
import 'package:cses_document_collab/src/editor/collab_image_block.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 通过真实工具栏和 Android 输入连接验证项内缩进，不连接真实 WS；确认仅模拟属性投影。
void main() {
  for (final source in ['numbered_list', 'bulleted_list', 'todo_list']) {
    for (final target in ['numbered_list', 'bulleted_list', 'todo_list']) {
      testWidgets(
        'type switch $source to $target retains rich text, depth and Android focus',
        (tester) async {
          final changes = <List<CollabEditorBlock>>[];
          final adapter = AppFlowyBlockEditorAdapter(
            initialBlocks: [
              CollabEditorBlock(
                id: 'item',
                blockType: source,
                text: '正文🙂测试',
                indent: 3,
                alignment: 'right',
                checked: source == 'todo_list',
                segments: const [
                  CollabEditorTextSegment(
                    text: '正文🙂测试',
                    bold: true,
                    italic: true,
                    underline: true,
                  ),
                ],
                ordered: source == 'numbered_list'
                    ? const CollabOrdered(
                        order: 4,
                        start: 5,
                        numbering: '{"start":5,"continuePrevious":false}',
                      )
                    : null,
              ),
            ],
            onLocalBlocksChanged: changes.add,
          );
          final state = adapter.editorState;
          final selection = Selection.single(path: [0], startOffset: 2);
          final focus = await _mount(
            tester,
            adapter,
            selection,
            menu: 'block-style',
          );
          // 清除来自旧选择手势的临时选区元数据是继续复用输入连接的必要条件。
          state.selectionExtraInfo = {'type': 'gesture'};
          await tester.ensureVisible(
            find.byKey(ValueKey('editor-block-$target-0')),
          );
          await tester.tap(find.byKey(ValueKey('editor-block-$target-0')));
          await tester.pump(const Duration(milliseconds: 150));
          if (source != target) {
            await adapter.replaceFromRemote(_projection(adapter.blocks));
            await tester.pump(const Duration(milliseconds: 150));
          }
          final block = adapter.blocks.single;
          expect(block.blockType, target);
          expect(block.indent, 3);
          expect(block.alignment, 'right');
          expect(block.segments.single.bold, isTrue);
          expect(block.segments.single.italic, isTrue);
          expect(block.segments.single.underline, isTrue);
          expect(block.checked, source == target && target == 'todo_list');
          expect(changes, hasLength(source == target ? 0 : 1));
          expect(state.selection, selection);
          expect(focus.hasFocus, isTrue);
          expect(tester.testTextInput.hasAnyClients, isTrue);
          expect(tester.testTextInput.isVisible, isTrue);
          if (source != target) {
            state.undoManager.undo();
            await tester.pump(const Duration(milliseconds: 150));
            expect(adapter.blocks.single.blockType, source);
            expect(adapter.blocks.single.checked, source == 'todo_list');
            expect(state.selection, selection);
            expect(focus.hasFocus, isTrue);
            state.undoManager.redo();
            await tester.pump(const Duration(milliseconds: 150));
          }
          final editing = TextEditingValue.fromJSON(
            tester.testTextInput.editingState!,
          );
          final caret = editing.selection.extentOffset;
          tester.testTextInput.updateEditingValue(
            editing.copyWith(
              text: editing.text.replaceRange(caret, caret, '中文'),
              selection: TextSelection.collapsed(offset: caret + 2),
              composing: TextRange.empty,
            ),
          );
          await tester.pump(const Duration(milliseconds: 150));
          expect(adapter.blocks.single.text, '正文中文🙂测试');
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }
  }
  for (final target in ['numbered_list', 'bulleted_list', 'todo_list']) {
    for (final reverse in [false, true]) {
      testWidgets(
        'type menu batch to $target reverse=$reverse retains selection and focus',
        (tester) async {
          final changes = <List<CollabEditorBlock>>[];
          final adapter = AppFlowyBlockEditorAdapter(
            initialBlocks: const [
              CollabEditorBlock(
                id: 'a',
                blockType: 'numbered_list',
                text: 'one two',
                ordered: CollabOrdered(order: 0),
              ),
              CollabEditorBlock(
                id: 'b',
                blockType: 'bulleted_list',
                text: 'one two',
                indent: 1,
              ),
              CollabEditorBlock(
                id: 'c',
                blockType: 'todo_list',
                text: 'one two',
                indent: 6,
                checked: true,
              ),
              CollabEditorBlock(
                id: 'image',
                blockType: 'image',
                text: '',
                image: CollabImage(),
              ),
            ],
            onLocalBlocksChanged: changes.add,
          );
          final state = adapter.editorState;
          final selection = Selection(
            start: Position(path: [reverse ? 2 : 0], offset: reverse ? 5 : 1),
            end: Position(path: [reverse ? 0 : 2], offset: reverse ? 1 : 5),
          );
          final focus = await _mount(
            tester,
            adapter,
            selection,
            menu: 'block-style',
          );
          final image = state.getNodeAtPath([3]);
          final hadClient = tester.testTextInput.hasAnyClients;
          await tester.ensureVisible(
            find.byKey(ValueKey('editor-block-$target-0')),
          );
          await tester.tap(find.byKey(ValueKey('editor-block-$target-0')));
          await tester.pump(const Duration(milliseconds: 150));
          final convertedNodes = state.document.root.children.toList();
          await adapter.replaceFromRemote(_projection(adapter.blocks));
          await tester.pump(const Duration(milliseconds: 150));
          expect(changes, hasLength(1));
          expect(
            adapter.blocks.take(3).map((b) => b.blockType),
            everyElement(target),
          );
          expect(adapter.blocks.take(3).map((b) => b.indent), [0, 1, 6]);
          expect(adapter.blocks.take(3).map((b) => b.checked), [
            false,
            false,
            target == 'todo_list',
          ]);
          expect(state.selection, selection);
          expect(focus.hasFocus, isTrue);
          expect(tester.testTextInput.hasAnyClients, hadClient);
          expect(state.getNodeAtPath([3]), same(image));
          for (var i = 0; i < 3; i++) {
            expect(state.getNodeAtPath([i]), same(convertedNodes[i]));
          }
          state.undoManager.undo();
          await tester.pump(const Duration(milliseconds: 150));
          expect(adapter.blocks.take(3).map((b) => b.blockType), [
            'numbered_list',
            'bulleted_list',
            'todo_list',
          ]);
          expect(adapter.blocks[2].checked, isTrue);
          expect(state.selection, selection);
          expect(focus.hasFocus, isTrue);
          state.undoManager.redo();
          await tester.pump(const Duration(milliseconds: 150));
          expect(
            adapter.blocks.take(3).map((b) => b.blockType),
            everyElement(target),
          );
          expect(state.selection, selection);
          expect(focus.hasFocus, isTrue);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }
  }
  for (final type in [
    NumberedListBlockKeys.type,
    BulletedListBlockKeys.type,
    TodoListBlockKeys.type,
  ]) {
    for (final offset in [0, 2]) {
      testWidgets(
        '$type toolbar at offset=$offset keeps content, checked state and focus',
        (tester) async {
          const text = '正文🙂测试';
          final adapter = AppFlowyBlockEditorAdapter(
            initialBlocks: [
              const CollabEditorBlock(
                id: 'previous',
                blockType: 'paragraph',
                text: '前文',
              ),
              CollabEditorBlock(
                id: 'item',
                blockType: type,
                text: text,
                indent: 1,
                segments: const [
                  CollabEditorTextSegment(text: text, bold: true),
                ],
                checked: type == TodoListBlockKeys.type,
                ordered: type == NumberedListBlockKeys.type
                    ? const CollabOrdered(
                        order: 4,
                        start: 5,
                        numbering: '{"start":5,"continuePrevious":false}',
                      )
                    : null,
              ),
              const CollabEditorBlock(
                id: 'image',
                blockType: 'image',
                text: '',
                image: CollabImage(),
              ),
            ],
            onLocalBlocksChanged: (_) {},
          );
          final state = adapter.editorState;
          final selection = Selection.single(path: [1], startOffset: offset);
          final focus = await _mount(tester, adapter, selection);
          final item = state.getNodeAtPath([1]);
          final image = state.getNodeAtPath([2]);
          for (final depth in [2, 1, 0, -1]) {
            await tester.tap(
              find.byKey(
                ValueKey(
                  depth == 2 ? 'editor-block-indent' : 'editor-block-outdent',
                ),
              ),
            );
            await tester.pump(const Duration(milliseconds: 150));
            await adapter.replaceFromRemote(_projection(adapter.blocks));
            await tester.pump(const Duration(milliseconds: 150));
            expect(adapter.blocks, hasLength(3));
            expect(adapter.blocks.first.text, '前文');
            expect(adapter.blocks[1].blockType, depth < 0 ? 'paragraph' : type);
            expect(adapter.blocks[1].indent, depth < 0 ? 0 : depth);
            expect(adapter.blocks[1].text, text);
            expect(adapter.blocks[1].segments.single.bold, isTrue);
            expect(
              adapter.blocks[1].checked,
              depth >= 0 && type == TodoListBlockKeys.type,
            );
            if (depth >= 0) {
              expect(state.getNodeAtPath([1]), same(item));
              if (type == NumberedListBlockKeys.type) {
                expect(adapter.blocks[1].ordered!.restarts, depth == 2);
              }
            }
            expect(state.getNodeAtPath([2]), same(image));
            expect(state.selection, selection);
            expect(focus.hasFocus, isTrue);
            expect(tester.testTextInput.hasAnyClients, isTrue);
            expect(tester.testTextInput.isVisible, isTrue);
          }
          final editing = TextEditingValue.fromJSON(
            tester.testTextInput.editingState!,
          );
          final caret = editing.selection.extentOffset;
          tester.testTextInput.updateEditingValue(
            editing.copyWith(
              text: editing.text.replaceRange(caret, caret, '中文'),
              selection: TextSelection.collapsed(offset: caret + 2),
              composing: TextRange.empty,
            ),
          );
          await tester.pump(const Duration(milliseconds: 150));
          expect(
            adapter.blocks[1].text,
            '${text.substring(0, offset)}中文${text.substring(offset)}',
          );
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }
  }
  for (final reverse in [false, true]) {
    testWidgets(
      'toolbar mixed range reverse=$reverse keeps range and focus through conversion',
      (tester) async {
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: const [
            CollabEditorBlock(
              id: 'previous',
              blockType: 'paragraph',
              text: '前文',
            ),
            CollabEditorBlock(
              id: 'a',
              blockType: 'numbered_list',
              text: 'one two',
              ordered: CollabOrdered(order: 0),
            ),
            CollabEditorBlock(
              id: 'b',
              blockType: 'bulleted_list',
              text: 'one two',
              indent: 1,
            ),
            CollabEditorBlock(
              id: 'c',
              blockType: 'todo_list',
              text: 'one two',
              indent: 2,
              checked: false,
            ),
            CollabEditorBlock(
              id: 'image',
              blockType: 'image',
              text: '',
              image: CollabImage(),
            ),
          ],
          onLocalBlocksChanged: (_) {},
        );
        final state = adapter.editorState;
        final selection = Selection(
          start: Position(path: reverse ? [3] : [1], offset: reverse ? 5 : 1),
          end: Position(path: reverse ? [1] : [3], offset: reverse ? 1 : 5),
        );
        final focus = await _mount(tester, adapter, selection);
        final hadClient = tester.testTextInput.hasAnyClients;
        final image = state.getNodeAtPath([4]);
        final expected = [
          [1, 2, 3],
          [0, 1, 2],
          [0, 0, 1],
        ];
        for (var step = 0; step < 3; step++) {
          await tester.tap(
            find.byKey(
              ValueKey(
                step == 0 ? 'editor-block-indent' : 'editor-block-outdent',
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 150));
          await adapter.replaceFromRemote(_projection(adapter.blocks));
          await tester.pump(const Duration(milliseconds: 150));
          expect(
            adapter.blocks.skip(1).take(3).map((b) => b.indent),
            expected[step],
          );
          expect(
            adapter.blocks[1].blockType,
            step == 2 ? 'paragraph' : 'numbered_list',
          );
          expect(adapter.blocks[3].checked, isFalse);
          expect(state.selection, selection);
          expect(focus.hasFocus, isTrue);
          expect(tester.testTextInput.hasAnyClients, hadClient);
          expect(state.getNodeAtPath([4]), same(image));
        }
        expect(_buttonEnabled(tester, 'editor-block-indent'), isFalse);
        expect(_buttonEnabled(tester, 'editor-block-outdent'), isFalse);
        state.undoManager.undo();
        await tester.pump(const Duration(milliseconds: 150));
        await adapter.replaceFromRemote(_projection(adapter.blocks));
        await tester.pump(const Duration(milliseconds: 150));
        expect(adapter.blocks[1].blockType, 'numbered_list');
        expect(adapter.blocks.skip(1).take(3).map((b) => b.indent), [0, 1, 2]);
        expect(state.selection, selection);
        expect(focus.hasFocus, isTrue);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
  testWidgets(
    'toolbar maximum depth disables increase and preserves unchecked Todo',
    (tester) async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'item',
            blockType: 'todo_list',
            text: 'one two',
            indent: 6,
          ),
        ],
        onLocalBlocksChanged: (_) {},
      );
      final state = adapter.editorState;
      final selection = Selection.single(path: [0], startOffset: 2);
      final focus = await _mount(tester, adapter, selection);
      expect(_buttonEnabled(tester, 'editor-block-indent'), isFalse);
      expect(_buttonEnabled(tester, 'editor-block-outdent'), isTrue);
      await tester.tap(find.byKey(const ValueKey('editor-block-indent')));
      await tester.pump();
      expect(adapter.blocks.single.indent, 6);
      await tester.tap(find.byKey(const ValueKey('editor-block-outdent')));
      await tester.pump(const Duration(milliseconds: 150));
      expect(adapter.blocks.single.indent, 5);
      expect(adapter.blocks.single.checked, isFalse);
      expect(state.selection, selection);
      expect(focus.hasFocus, isTrue);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}

/// 为借用的 [blocks] 生成确认投影；保留格式、勾选和媒体字段，移除本地替换来源/编号命令。
/// 编号取 depth 以触发原位属性回写，仅验证输入焦点；真实计数由原生测试覆盖。
List<CollabEditorBlock> _projection(List<CollabEditorBlock> blocks) => [
  for (final b in blocks)
    CollabEditorBlock(
      id: b.id,
      blockType: b.blockType,
      text: b.text,
      segments: b.segments,
      checked: b.checked,
      alignment: b.alignment,
      indent: b.indent,
      image: b.image,
      ordered: b.blockType == NumberedListBlockKeys.type
          ? CollabOrdered(
              order: b.indent,
              numbering: b.ordered?.numbering ?? '{}',
            )
          : null,
    ),
];

/// 为 [tester] 挂载真实工具栏，将 [adapter] 的测试清理责任交给本函数，恢复 [selection] 并展开菜单。
/// 创建的 FocusNode 和适配器在测试结束、Widget 卸载后释放；平台模拟处理也同步解除。
/// 多项选区先建立单点输入连接再切换范围；[menu] 默认 block-layout，可指定 block-style 类型菜单。
/// 返回借用的焦点供断言，不由调用方重复释放。
Future<FocusNode> _mount(
  WidgetTester tester,
  AppFlowyBlockEditorAdapter adapter,
  Selection selection, {
  String menu = 'block-layout',
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(
        const EventChannel('keyboardHeightEventChannel'),
        MockStreamHandler.inline(onListen: (_, events) => events.success(0.0)),
      );
  final focus = FocusNode();
  final state = adapter.editorState;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    adapter.dispose();
    focus.dispose();
    await tester.binding.setSurfaceSize(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          null,
        );
  });
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        AppFlowyEditorLocalizations.delegate,
      ],
      home: Scaffold(
        body: MediaQuery(
          data: const MediaQueryData(viewInsets: EdgeInsets.only(bottom: 300)),
          child: EditorShortcutToolbar(
            editorState: state,
            child: AppFlowyEditor(
              editorState: state,
              focusNode: focus,
              editorStyle: const EditorStyle.mobile(),
              blockComponentBuilders: {
                ...standardBlockComponentBuilderMap,
                'image': CollabImageBlockComponentBuilder(),
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  final first = selection.isCollapsed
      ? selection
      : Selection.single(
          path: selection.start.path,
          startOffset: selection.start.offset,
        );
  final selected = state.updateSelectionWithReason(
    first,
    reason: SelectionUpdateReason.uiEvent,
  );
  await tester.pump();
  await selected;
  await tester.pump(const Duration(milliseconds: 150));
  if (!selection.isCollapsed) {
    final ranged = state.updateSelectionWithReason(
      selection,
      reason: SelectionUpdateReason.uiEvent,
    );
    await tester.pump();
    await ranged;
    await tester.pump(const Duration(milliseconds: 150));
  }
  await tester.tap(find.byKey(ValueKey('editor-shortcut-$menu')));
  await tester.pump();
  return focus;
}

/// 读取 [tester] 中 [key] 指定布局按钮的实际命中处理器，返回是否启用；按钮必须已挂载。
bool _buttonEnabled(WidgetTester tester, String key) =>
    tester
        .widget<InkWell>(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(InkWell),
          ),
        )
        .onTap !=
    null;
