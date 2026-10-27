import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_ordered.dart';
import 'package:cses_document_collab/src/editor/collab_list_editing.dart';
import 'package:flutter_test/flutter_test.dart';

/// 覆盖列表互换、空项、层级、格式和原子历史，不连接真实 WS；每项拥有并释放适配器。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const types = ['numbered_list', 'bulleted_list', 'todo_list'];
  for (final source in types) {
    for (final target in types) {
      for (var depth = 0; depth <= 6; depth++) {
        for (final empty in [false, true]) {
          test('$source to $target depth=$depth empty=$empty', () async {
            final changes = <List<CollabEditorBlock>>[];
            final before = _block(source, 'item', depth, empty: empty);
            final adapter = AppFlowyBlockEditorAdapter(
              initialBlocks: [before],
              onLocalBlocksChanged: changes.add,
            );
            addTearDown(adapter.dispose);
            final state = adapter.editorState;
            final selection = Selection.single(
              path: [0],
              startOffset: empty ? 0 : 2,
            );
            state.selection = selection;
            final original = state.document.first;
            expect(await changeCollabListType(state, target), source != target);
            final after = adapter.blocks.single;
            expect(after.blockType, target);
            expect(after.indent, depth);
            expect(after.text, before.text);
            expect(after.segments, before.segments);
            expect(after.alignment, 'right');
            expect(after.checked, source == target && target == 'todo_list');
            expect(state.selection, selection);
            if (source == target) {
              expect(state.document.first, same(original));
              expect(after.ordered, before.ordered);
              expect(changes, isEmpty);
              expect(state.undoManager.undoStack.isEmpty, isTrue);
              return;
            }
            expect(changes, hasLength(1));
            expect(after.id, isNot(before.id));
            expect(after.replacesId, before.id);
            expect(after.ordered, isNull);
            if (target != 'todo_list') {
              expect(
                state.document.first!.attributes.containsKey(
                  TodoListBlockKeys.checked,
                ),
                isFalse,
              );
            }
            state.undoManager.undo();
            await Future<void>.delayed(Duration.zero);
            final undone = adapter.blocks.single;
            expect(undone.blockType, source);
            expect(undone.indent, depth);
            expect(undone.checked, before.checked);
            expect(undone.ordered?.numbering, before.ordered?.numbering);
            expect(undone.segments, before.segments);
            expect(state.selection, selection);
            state.undoManager.redo();
            await Future<void>.delayed(Duration.zero);
            expect(adapter.blocks.single.blockType, target);
            expect(adapter.blocks.single.checked, isFalse);
            expect(state.selection, selection);
            expect(changes, hasLength(3));
          });
        }
      }
    }
  }
  for (final target in types) {
    for (final reverse in [false, true]) {
      for (final selectionType in [SelectionType.inline, SelectionType.block]) {
        test(
          'batch to $target reverse=$reverse selection=$selectionType',
          () async {
            final changes = <List<CollabEditorBlock>>[];
            final adapter = AppFlowyBlockEditorAdapter(
              initialBlocks: [
                for (var i = 0; i < 3; i++) _block(types[i], 'item-$i', i),
              ],
              onLocalBlocksChanged: changes.add,
            );
            addTearDown(adapter.dispose);
            final state = adapter.editorState;
            final selection = Selection(
              start: Position(path: [reverse ? 2 : 0], offset: reverse ? 4 : 1),
              end: Position(path: [reverse ? 0 : 2], offset: reverse ? 1 : 4),
            );
            state.selection = selection;
            state.selectionType = selectionType;
            final unchangedIndex = types.indexOf(target);
            final unchanged = state.getNodeAtPath([unchangedIndex]);
            expect(await changeCollabListType(state, target), isTrue);
            expect(changes, hasLength(1));
            expect(
              adapter.blocks.map((b) => b.blockType),
              everyElement(target),
            );
            expect(adapter.blocks.map((b) => b.indent), [0, 1, 2]);
            expect(adapter.blocks.map((b) => b.checked), [
              false,
              false,
              target == 'todo_list',
            ]);
            expect(state.getNodeAtPath([unchangedIndex]), same(unchanged));
            expect(state.selection, selection);
            expect(state.selectionType, selectionType);
            state.undoManager.undo();
            await Future<void>.delayed(Duration.zero);
            expect(adapter.blocks.map((b) => b.blockType), types);
            expect(adapter.blocks.last.checked, isTrue);
            expect(
              adapter.blocks.first.ordered!.numbering,
              '{"start":5,"continuePrevious":false}',
            );
            state.undoManager.redo();
            await Future<void>.delayed(Duration.zero);
            expect(
              adapter.blocks.map((b) => b.blockType),
              everyElement(target),
            );
            expect(state.selection, selection);
            expect(changes, hasLength(3));
          },
        );
      }
    }
  }
  test(
    'invalid target, range, read-only, disposed and mixed blocks do not mutate',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          _block('todo_list', 'a', 2),
          _block('paragraph', 'b', 0),
        ],
        onLocalBlocksChanged: changes.add,
      );
      final state = adapter.editorState;
      for (final selection in [
        null,
        Selection.single(path: [0], startOffset: -1),
        Selection.single(path: [0], startOffset: 99),
        Selection.single(path: [9], startOffset: 0),
        Selection.single(path: [0, 0], startOffset: 0),
        Selection(
          start: Position(path: [0], offset: 0),
          end: Position(path: [1], offset: 1),
        ),
      ]) {
        state.selection = selection;
        expect(await changeCollabListType(state, 'numbered_list'), isFalse);
      }
      state.selection = Selection.single(path: [0], startOffset: 0);
      expect(await changeCollabListType(state, 'paragraph'), isFalse);
      state.editable = false;
      expect(await changeCollabListType(state, 'numbered_list'), isFalse);
      state.editable = true;
      expect(changes, isEmpty);
      adapter.dispose();
      expect(await changeCollabListType(state, 'numbered_list'), isFalse);
    },
  );
}

/// 创建 [type]、[id] 和 [depth] 指定的测试块；[empty] 默认 false，为 true 时正文/格式集合为空。
/// 有序块使用自定义起点和样式，Todo 已勾选；其余类型不携带列表专有数据，返回无资源的投影。
CollabEditorBlock _block(
  String type,
  String id,
  int depth, {
  bool empty = false,
}) => CollabEditorBlock(
  id: id,
  blockType: type,
  indent: depth,
  alignment: 'right',
  text: empty ? '' : '正文🙂测试',
  segments: empty
      ? const []
      : const [
          CollabEditorTextSegment(
            text: '正文🙂测试',
            bold: true,
            italic: true,
            underline: true,
            textColor: '0xff123456',
          ),
        ],
  checked: type == 'todo_list',
  ordered: type == 'numbered_list'
      ? const CollabOrdered(
          order: 4,
          start: 5,
          markerStyle: 'a2',
          numbering: '{"start":5,"continuePrevious":false}',
        )
      : null,
);
