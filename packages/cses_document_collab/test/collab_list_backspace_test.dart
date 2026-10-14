import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_ordered.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/editor/collab_list_editing.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证硬件退格入口的三种扁平列表退级，不连接真实 WS；各用例释放所属适配器。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final type in [
    NumberedListBlockKeys.type,
    BulletedListBlockKeys.type,
    TodoListBlockKeys.type,
  ]) {
    group(type, () {
      test(
        'actual nested nodes defer instead of changing flat depth',
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
            state.selection = Selection.single(path: path, startOffset: 0);
            expect(canOutdentCollabListAtStart(state), isFalse);
            expect(await outdentCollabListAtStart(state), isFalse);
            expect(
              collabBlockBackspaceCommand.execute(state),
              KeyEventResult.ignored,
            );
            expect(
              state.getNodeAtPath(path)!.attributes[csesBlockIndentAttribute],
              path.length == 1 ? 2 : 3,
            );
          }
        },
      );
      test(
        'IME distinguishes prefix Backspace from forward and composing deletion',
        () async {
          final adapter = _fixture(
            type,
            2,
            '正文🙂',
            preceding: ImageBlockKeys.type,
          );
          addTearDown(adapter.dispose);
          final state = adapter.editorState;
          state.selection = Selection.single(path: [1], startOffset: 0);
          final interceptor = CollabBlockBackspaceInterceptor();
          for (final deletion in [
            const TextEditingDeltaDeletion(
              oldText: '正文🙂',
              deletedRange: TextRange(start: 0, end: 1),
              selection: TextSelection.collapsed(offset: 0),
              composing: TextRange.empty,
            ),
            const TextEditingDeltaDeletion(
              oldText: '正文🙂',
              deletedRange: TextRange.collapsed(0),
              selection: TextSelection.collapsed(offset: 0),
              composing: TextRange(start: 0, end: 2),
            ),
          ]) {
            expect(await interceptor.interceptDelete(deletion, state), isFalse);
            expect(adapter.blocks, hasLength(2));
            expect(adapter.blocks.last.text, '正文🙂');
            expect(adapter.blocks.last.indent, 2);
          }
          expect(
            await interceptor.interceptDelete(
              const TextEditingDeltaDeletion(
                oldText: '正文🙂',
                deletedRange: TextRange.collapsed(0),
                selection: TextSelection.collapsed(offset: 0),
                composing: TextRange.empty,
              ),
              state,
            ),
            isTrue,
          );
          expect(adapter.blocks, hasLength(2));
          expect(adapter.blocks.last.indent, 1);
        },
      );
      for (var depth = 0; depth <= 6; depth++) {
        for (final text in ['', '正文🙂']) {
          test(
            'Backspace depth=$depth text=$text preserves content and caret',
            () async {
              final adapter = _fixture(type, depth, text);
              addTearDown(adapter.dispose);
              final state = adapter.editorState;
              final original = state.document.first;
              final segments = adapter.blocks.single.segments;
              state.selection = Selection.single(path: [0], startOffset: 0);
              expect(
                collabBlockBackspaceCommand.execute(state),
                KeyEventResult.handled,
              );
              await Future<void>.delayed(Duration.zero);
              expect(adapter.blocks, hasLength(1));
              expect(
                adapter.blocks.single.blockType,
                depth == 0 ? 'paragraph' : type,
              );
              expect(adapter.blocks.single.indent, depth == 0 ? 0 : depth - 1);
              expect(adapter.blocks.single.text, text);
              expect(adapter.blocks.single.segments, segments);
              expect(adapter.blocks.single.alignment, 'right');
              expect(
                adapter.blocks.single.checked,
                depth > 0 && type == TodoListBlockKeys.type,
              );
              expect(
                state.selection,
                Selection.single(path: [0], startOffset: 0),
              );
              if (depth > 0) {
                expect(state.document.first, same(original));
                expect(adapter.blocks.single.id, 'item');
                if (type == NumberedListBlockKeys.type) {
                  expect(
                    adapter.blocks.single.ordered!.continuesPrevious,
                    isTrue,
                  );
                }
              }
            },
          );
        }
      }
      for (final preceding in [
        ParagraphBlockKeys.type,
        QuoteBlockKeys.type,
        ImageBlockKeys.type,
      ]) {
        test('list outdent takes priority after $preceding', () async {
          final adapter = _fixture(type, 2, '正文🙂', preceding: preceding);
          addTearDown(adapter.dispose);
          final state = adapter.editorState;
          final before = adapter.blocks.first;
          state.selection = Selection.single(path: [1], startOffset: 0);
          expect(
            collabBlockBackspaceCommand.execute(state),
            KeyEventResult.handled,
          );
          await Future<void>.delayed(Duration.zero);
          expect(adapter.blocks, hasLength(2));
          expect(adapter.blocks.first, before);
          expect(adapter.blocks.last.indent, 1);
          expect(adapter.blocks.last.text, '正文🙂');
          expect(state.selection, Selection.single(path: [1], startOffset: 0));
        });
      }
      test(
        'consecutive Backspace, undo and redo preserve each depth and content',
        () async {
          final adapter = _fixture(type, 3, '正文🙂');
          addTearDown(adapter.dispose);
          final state = adapter.editorState;
          state.selection = Selection.single(path: [0], startOffset: 0);
          for (final depth in [2, 1, 0, -1]) {
            expect(
              collabBlockBackspaceCommand.execute(state),
              KeyEventResult.handled,
            );
            await Future<void>.delayed(Duration.zero);
            expect(
              adapter.blocks.single.blockType,
              depth < 0 ? 'paragraph' : type,
            );
            expect(adapter.blocks.single.indent, depth < 0 ? 0 : depth);
            expect(adapter.blocks.single.text, '正文🙂');
          }
          for (final depth in [0, 1, 2, 3]) {
            state.undoManager.undo();
            await Future<void>.delayed(Duration.zero);
            expect(adapter.blocks.single.blockType, type);
            expect(adapter.blocks.single.indent, depth);
            expect(
              adapter.blocks.single.checked,
              type == TodoListBlockKeys.type,
            );
            expect(
              state.selection,
              Selection.single(path: [0], startOffset: 0),
            );
          }
          if (type == NumberedListBlockKeys.type) {
            // 编号投影由 Rust 确认；无原生回调的单元测试检查 Undo 恢复的原始设置属性。
            expect(
              state.document.first!.attributes[csesOrderedNumberingAttribute],
              '{"start":5,"continuePrevious":false}',
            );
          }
          for (final depth in [2, 1, 0, -1]) {
            state.undoManager.redo();
            await Future<void>.delayed(Duration.zero);
            expect(
              adapter.blocks.single.blockType,
              depth < 0 ? 'paragraph' : type,
            );
            expect(adapter.blocks.single.indent, depth < 0 ? 0 : depth);
            expect(adapter.blocks.single.text, '正文🙂');
          }
        },
      );
      test(
        'range, middle caret, readonly and disposed states defer without edits',
        () async {
          final adapter = _fixture(type, 2, '正文🙂');
          final state = adapter.editorState;
          try {
            expect(
              collabBlockBackspaceCommand.execute(state),
              KeyEventResult.ignored,
            );
            state.selection = Selection.single(
              path: [0],
              startOffset: 0,
              endOffset: 2,
            );
            expect(
              collabBlockBackspaceCommand.execute(state),
              KeyEventResult.ignored,
            );
            state.selection = Selection.single(path: [0], startOffset: 2);
            expect(
              collabBlockBackspaceCommand.execute(state),
              KeyEventResult.ignored,
            );
            state.selection = Selection.single(path: [0], startOffset: 0);
            state.editable = false;
            expect(
              collabBlockBackspaceCommand.execute(state),
              KeyEventResult.ignored,
            );
            expect(adapter.blocks.single.indent, 2);
            expect(adapter.blocks.single.text, '正文🙂');
          } finally {
            adapter.dispose();
          }
          expect(
            collabBlockBackspaceCommand.execute(state),
            KeyEventResult.ignored,
          );
        },
      );
    });
  }
  test(
    'unchecked Todo stays unchecked through outdent, conversion and history',
    () async {
      final adapter = _fixture(
        TodoListBlockKeys.type,
        1,
        '正文🙂',
        checked: false,
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [0], startOffset: 0);
      for (final depth in [0, -1]) {
        expect(
          collabBlockBackspaceCommand.execute(state),
          KeyEventResult.handled,
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          adapter.blocks.single.blockType,
          depth < 0 ? 'paragraph' : TodoListBlockKeys.type,
        );
        expect(adapter.blocks.single.checked, isFalse);
      }
      for (final depth in [0, 1]) {
        state.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        expect(adapter.blocks.single.indent, depth);
        expect(adapter.blocks.single.blockType, TodoListBlockKeys.type);
        expect(adapter.blocks.single.checked, isFalse);
      }
      for (final depth in [0, -1]) {
        state.undoManager.redo();
        await Future<void>.delayed(Duration.zero);
        expect(
          adapter.blocks.single.blockType,
          depth < 0 ? 'paragraph' : TodoListBlockKeys.type,
        );
        expect(adapter.blocks.single.checked, isFalse);
      }
    },
  );
}

/// 创建 [type] 列表，[depth] 为 0～6，[text] 支持空正文；待办项为已勾选以检查状态保留。
/// [preceding] 为可选前置块类型，null 表示没有前项。[checked] 默认 true，仅用于待办项勾选。
/// 返回适配器由调用方释放；正文带粗体和右对齐。
AppFlowyBlockEditorAdapter _fixture(
  String type,
  int depth,
  String text, {
  String? preceding,
  bool checked = true,
}) => AppFlowyBlockEditorAdapter(
  initialBlocks: [
    if (preceding != null)
      CollabEditorBlock(
        id: 'before',
        blockType: preceding,
        text: preceding == ImageBlockKeys.type ? '' : '前文',
      ),
    CollabEditorBlock(
      id: 'item',
      blockType: type,
      text: text,
      indent: depth,
      alignment: 'right',
      checked: type == TodoListBlockKeys.type && checked,
      segments: text.isEmpty
          ? const []
          : [CollabEditorTextSegment(text: text, bold: true)],
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
