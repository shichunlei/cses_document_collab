import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_indent.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_test/flutter_test.dart';

/// 验证文字段平面缩进、桌面边界与字段级历史，不建立AppFlowy嵌套结构。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final type in ['paragraph', 'heading_3', 'quote']) {
    test(
      '$type changes depth and preserves text, type and selection through history',
      () async {
        final published = <List<CollabEditorBlock>>[];
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: [
            _block('previous', depth: 2),
            _block('target', type: type),
          ],
          onLocalBlocksChanged: published.add,
        );
        addTearDown(adapter.dispose);
        final state = adapter.editorState;
        final selection = Selection.single(path: [1], startOffset: 1);
        state.selection = selection;
        expect(await changeCollabBlockIndent(state, 1), isTrue);
        expect(collabParagraphDepth(state.document.last!), 1);
        expect(state.selection, selection);
        expect(adapter.blocks.last.blockType, type);
        expect(adapter.blocks.last.text, '正文');
        expect(state.document.root.children, hasLength(2));
        expect(
          published.last.last.paragraphStyle!.propertyEdits,
          contains('depth'),
        );
        state.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        expect(collabParagraphDepth(state.document.last!), 0);
        state.undoManager.redo();
        await Future<void>.delayed(Duration.zero);
        expect(collabParagraphDepth(state.document.last!), 1);
        expect(await changeCollabBlockIndent(state, -1), isTrue);
        expect(adapter.blocks.last.blockType, type);
        expect(collabParagraphDepth(state.document.last!), 0);
      },
    );
  }
  test(
    'first sibling is limited to depth one; zero outdent is a no-op',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [_block('first')],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [0], startOffset: 0);
      expect(canChangeCollabBlockIndent(state, -1), isFalse);
      expect(await changeCollabBlockIndent(state, 1), isTrue);
      expect(await changeCollabBlockIndent(state, 1), isFalse);
      expect(collabParagraphDepth(state.document.first!), 1);
    },
  );
  test(
    'eight-level and previous sibling caps reject entire reversed range',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          _block('previous', depth: 7),
          _block('a', depth: 1),
          _block('b', depth: 8),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection(
        start: Position(path: [2], offset: 2),
        end: Position(path: [1], offset: 0),
      );
      final before = state.document.toJson();
      expect(await changeCollabBlockIndent(state, 1), isFalse);
      expect(state.document.toJson(), before);
      expect(await changeCollabBlockIndent(state, -1), isTrue);
      expect(collabParagraphDepth(state.document.nodeAtPath([1])!), 0);
      expect(collabParagraphDepth(state.document.last!), 7);
    },
  );
  test(
    'eight and legacy over-cap values remain intact until explicit outdent',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          _block('previous', depth: 7),
          _block('target', depth: 7),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [1], startOffset: 0);
      expect(await changeCollabBlockIndent(state, 1), isTrue);
      expect(collabParagraphDepth(state.document.last!), 8);
      expect(await changeCollabBlockIndent(state, 1), isFalse);
      await adapter.replaceFromRemote([
        _block('previous', depth: 7),
        _block('target', depth: 10),
      ]);
      expect(collabParagraphDepth(state.document.last!), 10);
      expect(await changeCollabBlockIndent(state, -1), isTrue);
      expect(collabParagraphDepth(state.document.last!), 9);
    },
  );
  test(
    'undo follows stable target after remote reorder and preserves remote appearance',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [_block('previous', depth: 2), _block('target')],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [1], startOffset: 0);
      await changeCollabBlockIndent(state, 1);
      await adapter.replaceFromRemote([
        CollabEditorBlock(
          id: 'target',
          blockType: 'paragraph',
          text: '远端文字',
          paragraphStyle: CollabResource.fromValues({'depth': 1, 'fs': 22}),
        ),
        _block('previous', depth: 2),
      ]);
      state.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(collabParagraphDepth(state.document.first!), 0);
      expect(adapter.blocks.first.text, '远端文字');
      expect(readCollabParagraph(state.document.first!).values['fs'], 22);
      expect(collabParagraphDepth(state.document.last!), 2);
    },
  );
  test(
    'hardware Tab uses flat depth; table navigation and code are untouched',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [_block('target')],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [0], startOffset: 0);
      expect(collabParagraphTabCommand.handler(state), KeyEventResult.handled);
      await Future<void>.delayed(Duration.zero);
      expect(collabParagraphDepth(state.document.first!), 1);
      expect(
        collabParagraphShiftTabCommand.handler(state),
        KeyEventResult.handled,
      );
      await Future<void>.delayed(Duration.zero);
      expect(collabParagraphDepth(state.document.first!), 0);
      final table = EditorState(
        document: Document(
          root: Node(
            type: 'page',
            children: [
              Node(
                type: 'table-cell',
                children: [paragraphNode(text: '单元格')],
              ),
            ],
          ),
        ),
      );
      addTearDown(table.dispose);
      table.selection = Selection.single(path: [0, 0], startOffset: 0);
      expect(collabParagraphTabCommand.handler(table), KeyEventResult.ignored);
    },
  );
  test('readonly and mixed code/text selections do not write', () async {
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: [
        _block('target'),
        const CollabEditorBlock(id: 'code', blockType: 'code', text: 'code'),
      ],
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    state.selection = Selection(
      start: Position(path: [0], offset: 0),
      end: Position(path: [1], offset: 4),
    );
    expect(await changeCollabBlockIndent(state, 1), isFalse);
    state.selection = Selection.single(path: [0], startOffset: 0);
    state.editable = false;
    expect(await changeCollabBlockIndent(state, 1), isFalse);
  });
}

/// 创建 [id] 的 [type] 文本段，以原始 [depth] 初始化，不修改其他字段。
CollabEditorBlock _block(
  String id, {
  String type = 'paragraph',
  int depth = 0,
}) => CollabEditorBlock(
  id: id,
  blockType: type,
  text: '正文',
  paragraphStyle: CollabResource.fromValues({'depth': depth}),
);
