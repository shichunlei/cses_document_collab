import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:cses_mobile_collab_demo/src/collab/collab_ordered.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_list_editing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证扁平 depth 的列表回车规则，不连接真实文档；适配器由各测试释放。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final type in [
    NumberedListBlockKeys.type,
    BulletedListBlockKeys.type,
    TodoListBlockKeys.type,
  ]) {
    group(type, () {
      test(
        'partial undo keeps consecutive redo and independent undo boundaries',
        () async {
          final adapter = _adapter(3, 'one two', type: type);
          addTearDown(adapter.dispose);
          final state = adapter.editorState;
          state.selection = Selection.single(path: [0], startOffset: 7);
          for (var i = 0; i < 4; i++) {
            await collabListEnter.handler(state);
          }
          for (final depth in [1, 2]) {
            state.undoManager.undo();
            await Future<void>.delayed(Duration.zero);
            expect(adapter.blocks.last.indent, depth);
          }
          for (final depth in [1, 0]) {
            state.undoManager.redo();
            await Future<void>.delayed(const Duration(milliseconds: 60));
            expect(adapter.blocks.last.indent, depth);
            expect(state.undoManager.undoStack.last.sealed, isTrue);
            if (depth == 1) {
              expect(state.undoManager.redoStack.isNonEmpty, isTrue);
            }
          }
          for (final depth in [1, 2]) {
            state.undoManager.undo();
            await Future<void>.delayed(Duration.zero);
            expect(adapter.blocks.last.indent, depth);
            expect(adapter.blocks, hasLength(2));
          }
        },
      );
      test(
        'new input after undoing every command invalidates pending redo',
        () async {
          final adapter = _adapter(1, '', type: type);
          addTearDown(adapter.dispose);
          final state = adapter.editorState;
          state.selection = Selection.single(path: [0], startOffset: 0);
          await collabListEnter.handler(state);
          state.undoManager.undo();
          await Future<void>.delayed(Duration.zero);
          expect(state.undoManager.undoStack.isEmpty, isTrue);
          expect(state.undoManager.redoStack.isNonEmpty, isTrue);
          await state.insertTextAtPosition('新正文');
          expect(state.undoManager.redoStack.isEmpty, isTrue);
          state.undoManager.redo();
          await Future<void>.delayed(Duration.zero);
          expect(adapter.blocks.single.indent, 1);
          expect(adapter.blocks.single.text, '新正文');
        },
      );
      test(
        'consecutive empty Enter exits each ancestor then becomes a paragraph',
        () async {
          final adapter = _adapter(3, 'one two', type: type);
          addTearDown(adapter.dispose);
          final state = adapter.editorState;
          state.selection = Selection.single(path: [0], startOffset: 7);
          await collabListEnter.handler(state);
          for (final depth in [3, 2, 1, 0]) {
            expect(adapter.blocks.last.blockType, type);
            expect(adapter.blocks.last.indent, depth);
            expect(adapter.blocks, hasLength(2));
            expect(
              state.selection,
              Selection.single(path: [1], startOffset: 0),
            );
            await collabListEnter.handler(state);
          }
          expect(adapter.blocks.last.blockType, 'paragraph');
          expect(adapter.blocks.last.indent, 0);
          expect(adapter.blocks, hasLength(2));
          await state.insertTextAtPosition('普通正文');
          expect(adapter.blocks.last.text, '普通正文');
        },
      );

      test(
        'typing after outdent makes the next Enter create a same-level item',
        () async {
          final adapter = _adapter(2, 'one two', type: type);
          addTearDown(adapter.dispose);
          final state = adapter.editorState;
          state.selection = Selection.single(path: [0], startOffset: 7);
          await collabListEnter.handler(state);
          await collabListEnter.handler(state);
          await state.insertTextAtPosition('中文');
          await collabListEnter.handler(state);
          expect(adapter.blocks, hasLength(3));
          expect(adapter.blocks[1].text, '中文');
          expect(adapter.blocks[1].indent, 1);
          expect(adapter.blocks[2].indent, 1);
          expect(state.selection, Selection.single(path: [2], startOffset: 0));
        },
      );

      test(
        'unselected readonly and ranged selections defer without edits',
        () async {
          final adapter = _adapter(2, 'one two', type: type);
          addTearDown(adapter.dispose);
          final state = adapter.editorState;
          expect(await collabListEnter.handler(state), isFalse);
          state.selection = Selection.single(
            path: [0],
            startOffset: 1,
            endOffset: 3,
          );
          expect(await collabListEnter.handler(state), isFalse);
          state.selection = Selection.single(path: [0], startOffset: 3);
          state.editable = false;
          expect(await collabListEnter.handler(state), isFalse);
          expect(adapter.blocks.single.text, 'one two');
          expect(adapter.blocks.single.indent, 2);
        },
      );

      testWidgets('Shift Enter defers to soft line break handling', (
        tester,
      ) async {
        final adapter = _adapter(2, 'one two', type: type);
        addTearDown(adapter.dispose);
        adapter.editorState.selection = Selection.single(
          path: [0],
          startOffset: 3,
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        try {
          expect(await collabListEnter.handler(adapter.editorState), isFalse);
          expect(adapter.blocks, hasLength(1));
        } finally {
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        }
      });
      for (var depth = 0; depth <= 6; depth++) {
        for (final offset in [0, 3, 7]) {
          test(
            'Enter at $offset preserves depth $depth and splits formatted text',
            () async {
              final adapter = _adapter(depth, 'one two', type: type);
              addTearDown(adapter.dispose);
              final state = adapter.editorState;
              final original = state.document.first!;
              state.selection = Selection.single(
                path: [0],
                startOffset: offset,
              );
              expect(await collabListEnter.handler(state), isTrue);
              expect(adapter.blocks, hasLength(2));
              expect(adapter.blocks[0].text, 'one two'.substring(0, offset));
              expect(adapter.blocks[1].text, 'one two'.substring(offset));
              expect(adapter.blocks[1].indent, depth);
              expect(adapter.blocks[1].blockType, type);
              expect(adapter.blocks[1].alignment, 'right');
              expect(adapter.blocks[1].id, isNot(adapter.blocks[0].id));
              expect(adapter.blocks[1].ordered, isNull);
              expect(adapter.blocks[0].checked, type == TodoListBlockKeys.type);
              expect(adapter.blocks[1].checked, isFalse);
              if (type == TodoListBlockKeys.type) {
                expect(
                  state.getNodeAtPath([
                    1,
                  ])!.attributes[TodoListBlockKeys.checked],
                  isFalse,
                );
              }
              expect(state.document.first, same(original));
              expect(
                state.selection,
                Selection.single(path: [1], startOffset: 0),
              );
              if (offset < 7) {
                expect(adapter.blocks[1].segments.single.bold, isTrue);
              }
            },
          );
        }
      }
      for (var depth = 1; depth <= 6; depth++) {
        test(
          'empty depth $depth exits one level without inserting a node',
          () async {
            final adapter = _adapter(depth, '', type: type);
            addTearDown(adapter.dispose);
            final state = adapter.editorState;
            final node = state.document.first!;
            state.selection = Selection.single(path: [0], startOffset: 0);
            expect(await collabListEnter.handler(state), isTrue);
            expect(adapter.blocks.single.blockType, type);
            expect(adapter.blocks.single.indent, depth - 1);
            expect(state.document.first, same(node));
            expect(
              adapter.blocks.single.checked,
              type == TodoListBlockKeys.type,
            );
            expect(
              state.selection,
              Selection.single(path: [0], startOffset: 0),
            );
          },
        );
      }
      test(
        'each empty outdent and paragraph conversion undo redo separately',
        () async {
          final adapter = _adapter(3, '', type: type);
          addTearDown(adapter.dispose);
          final state = adapter.editorState;
          state.selection = Selection.single(path: [0], startOffset: 0);
          for (final depth in [2, 1, 0, -1]) {
            await collabListEnter.handler(state);
            expect(adapter.blocks.single.indent, depth < 0 ? 0 : depth);
            expect(
              adapter.blocks.single.blockType,
              depth < 0 ? 'paragraph' : type,
            );
          }
          for (final depth in [0, 1, 2, 3]) {
            state.undoManager.undo();
            await Future<void>.delayed(Duration.zero);
            expect(adapter.blocks.single.indent, depth);
            expect(
              adapter.blocks.single.checked,
              type == TodoListBlockKeys.type,
            );
            expect(adapter.blocks.single.blockType, type);
            expect(
              state.selection,
              Selection.single(path: [0], startOffset: 0),
            );
          }
          for (final depth in [2, 1, 0, -1]) {
            state.undoManager.redo();
            await Future<void>.delayed(Duration.zero);
            expect(adapter.blocks.single.indent, depth < 0 ? 0 : depth);
            expect(
              adapter.blocks.single.blockType,
              depth < 0 ? 'paragraph' : type,
            );
          }
        },
      );
    });
  }
  for (final checked in [false, true]) {
    test(
      'Todo checked=$checked survives split and empty outdent history',
      () async {
        final adapter = _adapter(
          2,
          'one two',
          type: TodoListBlockKeys.type,
          checked: checked,
        );
        final empty = _adapter(
          2,
          '',
          type: TodoListBlockKeys.type,
          checked: checked,
        );
        addTearDown(adapter.dispose);
        addTearDown(empty.dispose);
        final state = adapter.editorState;
        state.selection = Selection.single(path: [0], startOffset: 3);
        expect(await collabListEnter.handler(state), isTrue);
        expect(adapter.blocks.map((b) => b.checked), [checked, false]);
        state.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        expect(adapter.blocks.single.text, 'one two');
        expect(adapter.blocks.single.checked, checked);
        state.undoManager.redo();
        await Future<void>.delayed(Duration.zero);
        expect(adapter.blocks.map((b) => b.checked), [checked, false]);

        final emptyState = empty.editorState;
        emptyState.selection = Selection.single(path: [0], startOffset: 0);
        for (final depth in [1, 0]) {
          expect(await collabListEnter.handler(emptyState), isTrue);
          expect(empty.blocks.single.indent, depth);
          expect(empty.blocks.single.checked, checked);
        }
        await collabListEnter.handler(emptyState);
        expect(empty.blocks.single.blockType, 'paragraph');
        expect(empty.blocks.single.checked, isFalse);
        for (final depth in [0, 1, 2]) {
          emptyState.undoManager.undo();
          await Future<void>.delayed(Duration.zero);
          expect(empty.blocks.single.blockType, TodoListBlockKeys.type);
          expect(empty.blocks.single.indent, depth);
          expect(empty.blocks.single.checked, checked);
        }
        for (final depth in [1, 0, -1]) {
          emptyState.undoManager.redo();
          await Future<void>.delayed(Duration.zero);
          expect(
            empty.blocks.single.blockType,
            depth < 0 ? 'paragraph' : TodoListBlockKeys.type,
          );
          expect(empty.blocks.single.indent, depth < 0 ? 0 : depth);
          expect(empty.blocks.single.checked, depth < 0 ? false : checked);
        }
      },
    );
  }
  test(
    'outdent and original restart setting undo redo independently',
    () async {
      final adapter = _adapter(3, '');
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [0], startOffset: 0);
      await collabListEnter.handler(state);
      expect(
        adapter.blocks.single.ordered!.numbering,
        '{"start":0,"continuePrevious":true}',
      );
      await collabListEnter.handler(state);
      expect(adapter.blocks.single.indent, 1);
      for (final depth in [2, 3]) {
        state.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        expect(adapter.blocks.single.indent, depth);
      }
      expect(adapter.blocks.single.ordered!.restarts, isTrue);
      for (final depth in [2, 1]) {
        state.undoManager.redo();
        await Future<void>.delayed(Duration.zero);
        expect(adapter.blocks.single.indent, depth);
      }
      expect(adapter.blocks.single.ordered!.restarts, isFalse);
    },
  );
}

/// 创建粗体列表；[depth] 为 0～6 层级，[text] 可为空；[type] 默认有序列表，
/// 也支持 bulleted_list/todo_list。[checked] 默认 true，仅对待办项生效，
/// 验证原项勾选不被拆分/退级覆盖。有序项带原始起点；所有项右对齐以验证布局继承。
/// 返回适配器归调用方持有，新项不得复制原始起点或协同身份。
AppFlowyBlockEditorAdapter _adapter(
  int depth,
  String text, {
  String type = NumberedListBlockKeys.type,
  bool checked = true,
}) => AppFlowyBlockEditorAdapter(
  initialBlocks: [
    CollabEditorBlock(
      id: 'item',
      blockType: type,
      checked: type == TodoListBlockKeys.type && checked,
      text: text,
      segments: text.isEmpty
          ? const []
          : [CollabEditorTextSegment(text: text, bold: true)],
      indent: depth,
      alignment: 'right',
      ordered: type == NumberedListBlockKeys.type
          ? const CollabOrdered(
              order: 4,
              start: 5,
              numbering: '{"start":5,"continuePrevious":false}',
            )
          : null,
    ),
  ],
  onLocalBlocksChanged: (_) {},
);
