import 'dart:convert';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_ordered.dart';
import 'package:cses_document_collab/src/editor/collab_list_editing.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证工具栏共用层级事务、范围选区和最小逆操作；适配器由每项测试释放，不连接 WS。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final type in [
    NumberedListBlockKeys.type,
    BulletedListBlockKeys.type,
    TodoListBlockKeys.type,
  ]) {
    test(
      '$type actual child structure is disabled for toolbar indentation',
      () async {
        final state = EditorState(
          document: Document(
            root: Node(
              type: 'page',
              children: [
                Node(
                  type: type,
                  attributes: {
                    'delta': (Delta()..insert('父项')).toJson(),
                    csesBlockIndentAttribute: 2,
                  },
                  children: [
                    Node(
                      type: type,
                      attributes: {
                        'delta': (Delta()..insert('子项')).toJson(),
                        csesBlockIndentAttribute: 3,
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
        addTearDown(state.dispose);
        for (final path in [
          [0],
          [0, 0],
        ]) {
          state.selection = Selection.single(path: path, startOffset: 1);
          for (final delta in [-1, 1]) {
            expect(canChangeCollabListIndent(state, delta), isFalse);
            expect(await changeCollabListIndent(state, delta), isFalse);
          }
          expect(
            state.getNodeAtPath(path)!.attributes[csesBlockIndentAttribute],
            path.length == 1 ? 2 : 3,
          );
        }
      },
    );
    for (var depth = 0; depth <= 6; depth++) {
      for (final delta in [-1, 1]) {
        test(
          '$type depth=$depth delta=$delta keeps mid-item caret and history',
          () async {
            final changes = <List<CollabEditorBlock>>[];
            final adapter = _adapter([_block(type, 'item', depth)], changes);
            addTearDown(adapter.dispose);
            final state = adapter.editorState;
            final selection = Selection.single(path: [0], startOffset: 3);
            state.selection = selection;
            final before = adapter.blocks.single;
            final node = state.document.first;
            final allowed = delta < 0 || depth < 6;
            expect(canChangeCollabListIndent(state, delta), allowed);
            expect(await changeCollabListIndent(state, delta), allowed);
            if (!allowed) {
              expect(adapter.blocks.single, before);
              expect(changes, isEmpty);
              expect(state.undoManager.undoStack.isEmpty, isTrue);
              return;
            }
            final converted = delta < 0 && depth == 0;
            final after = adapter.blocks.single;
            expect(changes, hasLength(1));
            expect(after.blockType, converted ? 'paragraph' : type);
            expect(after.indent, converted ? 0 : depth + delta);
            expect(after.text, before.text);
            expect(after.segments, before.segments);
            expect(after.alignment, before.alignment);
            expect(after.checked, !converted && type == TodoListBlockKeys.type);
            expect(state.selection, selection);
            if (!converted) {
              expect(state.document.first, same(node));
              expect(after.id, 'item');
              expect(
                changes.single.single.ordered?.numberingEdit != null,
                type == NumberedListBlockKeys.type && delta < 0,
              );
            }
            state.undoManager.undo();
            await Future<void>.delayed(Duration.zero);
            expect(adapter.blocks.single.blockType, type);
            expect(adapter.blocks.single.indent, depth);
            expect(
              adapter.blocks.single.checked,
              type == TodoListBlockKeys.type,
            );
            expect(state.selection, selection);
            state.undoManager.redo();
            await Future<void>.delayed(Duration.zero);
            expect(
              adapter.blocks.single.blockType,
              converted ? 'paragraph' : type,
            );
            expect(adapter.blocks.single.indent, converted ? 0 : depth + delta);
            expect(adapter.blocks.single.text, before.text);
          },
        );
      }
    }
    test(
      '$type empty item increases then outdents to paragraph with one-step undo',
      () async {
        final changes = <List<CollabEditorBlock>>[];
        final adapter = _adapter([_block(type, 'empty', 0, text: '')], changes);
        addTearDown(adapter.dispose);
        final state = adapter.editorState;
        state.selection = Selection.single(path: [0], startOffset: 0);
        for (final delta in [1, -1, -1]) {
          expect(await changeCollabListIndent(state, delta), isTrue);
        }
        expect(adapter.blocks.single.blockType, 'paragraph');
        expect(adapter.blocks.single.text, '');
        state.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        expect(adapter.blocks.single.blockType, type);
        expect(adapter.blocks.single.indent, 0);
        expect(adapter.blocks.single.checked, type == TodoListBlockKeys.type);
      },
    );
    test(
      '$type depth history does not restore remote text, checked or formatting',
      () async {
        final changes = <List<CollabEditorBlock>>[];
        final adapter = _adapter([_block(type, 'item', 1)], changes);
        addTearDown(adapter.dispose);
        final state = adapter.editorState;
        state.selection = Selection.single(path: [0], startOffset: 3);
        await changeCollabListIndent(state, 1);
        await adapter.replaceFromRemote([
          CollabEditorBlock(
            id: 'item',
            blockType: type,
            text: '远端正文',
            indent: 2,
            alignment: 'center',
            checked: false,
            segments: const [
              CollabEditorTextSegment(text: '远端正文', italic: true),
            ],
            ordered: type == NumberedListBlockKeys.type
                ? const CollabOrdered(
                    order: 6,
                    start: 7,
                    markerStyle: 'A2',
                    numbering: '{"start":7}',
                  )
                : null,
          ),
        ]);
        for (final undo in [true, false]) {
          if (undo) {
            state.undoManager.undo();
          } else {
            state.undoManager.redo();
          }
          await Future<void>.delayed(Duration.zero);
          final current = adapter.blocks.single;
          expect(current.indent, undo ? 1 : 2);
          expect(current.text, '远端正文');
          expect(current.checked, isFalse);
          expect(current.alignment, 'center');
          expect(current.segments.single.italic, isTrue);
          if (type == NumberedListBlockKeys.type) {
            expect(current.ordered!.markerStyle, 'A2');
            expect(current.ordered!.numbering, '{"start":7}');
          }
        }
        expect(changes, hasLength(3));
      },
    );
  }
  for (final reverse in [false, true]) {
    for (final selectionType in [SelectionType.inline, SelectionType.block]) {
      test(
        'mixed list range reverse=$reverse type=$selectionType is one atomic history item',
        () async {
          final changes = <List<CollabEditorBlock>>[];
          final adapter = _adapter([
            _block('numbered_list', 'a', 0),
            _block('bulleted_list', 'b', 1),
            _block('todo_list', 'c', 2),
          ], changes);
          addTearDown(adapter.dispose);
          final state = adapter.editorState;
          final selection = Selection(
            start: Position(path: reverse ? [2] : [0], offset: reverse ? 5 : 1),
            end: Position(path: reverse ? [0] : [2], offset: reverse ? 1 : 5),
          );
          state.selection = selection;
          state.selectionType = selectionType;
          expect(await changeCollabListIndent(state, -1), isTrue);
          expect(changes, hasLength(1));
          expect(adapter.blocks.map((b) => b.blockType), [
            'paragraph',
            'bulleted_list',
            'todo_list',
          ]);
          expect(adapter.blocks.map((b) => b.indent), [0, 0, 1]);
          expect(adapter.blocks.last.checked, isTrue);
          expect(state.selection, selection);
          expect(state.selectionType, selectionType);
          // 非列表混入后整体禁用，避免第二次点击只修改其中一部分。
          expect(await changeCollabListIndent(state, -1), isFalse);
          expect(await changeCollabListIndent(state, 1), isFalse);
          state.undoManager.undo();
          await Future<void>.delayed(Duration.zero);
          expect(adapter.blocks.map((b) => b.blockType), [
            'numbered_list',
            'bulleted_list',
            'todo_list',
          ]);
          expect(adapter.blocks.map((b) => b.indent), [0, 1, 2]);
          expect(state.selection, selection);
          state.undoManager.redo();
          await Future<void>.delayed(Duration.zero);
          expect(adapter.blocks.map((b) => b.blockType), [
            'paragraph',
            'bulleted_list',
            'todo_list',
          ]);
          expect(adapter.blocks.map((b) => b.indent), [0, 0, 1]);
          expect(state.selection, selection);
          expect(changes, hasLength(3));
        },
      );
    }
  }
  test(
    'batch increase changes all three list types and a single undo restores all',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = _adapter([
        _block('numbered_list', 'a', 0),
        _block('bulleted_list', 'b', 1),
        _block('todo_list', 'c', 2, checked: false),
      ], changes);
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection(
        start: Position(path: [0], offset: 2),
        end: Position(path: [2], offset: 4),
      );
      expect(await changeCollabListIndent(state, 1), isTrue);
      expect(adapter.blocks.map((b) => b.indent), [1, 2, 3]);
      expect(adapter.blocks.last.checked, isFalse);
      expect(changes, hasLength(1));
      state.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(adapter.blocks.map((b) => b.indent), [0, 1, 2]);
      expect(adapter.blocks.last.checked, isFalse);
    },
  );
  test(
    'one maximum-depth item prevents partial increase; invalid and readonly selections do nothing',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = _adapter([
        _block('numbered_list', 'a', 0),
        _block('todo_list', 'b', 6),
      ], changes);
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      expect(await changeCollabListIndent(state, -1), isFalse);
      state.selection = Selection(
        start: Position(path: [0], offset: 0),
        end: Position(path: [1], offset: 3),
      );
      expect(canChangeCollabListIndent(state, 1), isFalse);
      expect(await changeCollabListIndent(state, 1), isFalse);
      for (final delta in [0, 2, -2]) {
        expect(await changeCollabListIndent(state, delta), isFalse);
      }
      state.editable = false;
      expect(await changeCollabListIndent(state, -1), isFalse);
      state.editable = true;
      state.selection = Selection.single(path: [8], startOffset: 0);
      expect(await changeCollabListIndent(state, -1), isFalse);
      state.selection = Selection.single(path: [0], startOffset: 90);
      expect(await changeCollabListIndent(state, -1), isFalse);
      expect(adapter.blocks.map((b) => b.indent), [0, 6]);
      expect(changes, isEmpty);
      expect(state.undoManager.undoStack.isEmpty, isTrue);
      adapter.dispose();
      expect(await changeCollabListIndent(state, -1), isFalse);
    },
  );
}

/// 创建 [type]/[id] 指定的测试块，[depth] 为 0～6；[checked] 默认 true，仅对 Todo 生效。
/// [text] 默认为 one two，可传空字符串；非空正文带粗体、右对齐。有序项使用起点 5，便于检查增加保留、退级恢复接续及撤销。
CollabEditorBlock _block(
  String type,
  String id,
  int depth, {
  bool checked = true,
  String text = 'one two',
}) => CollabEditorBlock(
  id: id,
  blockType: type,
  text: text,
  indent: depth,
  checked: type == TodoListBlockKeys.type && checked,
  alignment: 'right',
  segments: text.isEmpty
      ? const []
      : [CollabEditorTextSegment(text: text, bold: true)],
  ordered: type == NumberedListBlockKeys.type
      ? CollabOrdered(
          order: 4,
          start: 5,
          numbering: jsonEncode({'start': 5, 'continuePrevious': false}),
        )
      : null,
);

/// 用借用的 [blocks] 初始化适配器；[changes] 接收本地完整快照，远端投影不写入它。
/// 返回适配器和其 EditorState 由调用方通过 dispose 统一释放，不连接 Rust 或真实网络。
AppFlowyBlockEditorAdapter _adapter(
  List<CollabEditorBlock> blocks,
  List<List<CollabEditorBlock>> changes,
) => AppFlowyBlockEditorAdapter(
  initialBlocks: blocks,
  onLocalBlocksChanged: changes.add,
);
