import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证普通正文远端回放后丢弃过期路径/全文历史，保留稳定身份字段命令。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final change in ['text', 'reorder', 'format']) {
    test(
      '$change invalidates unsafe undo without overwriting remote content',
      () async {
        final adapter = _adapter();
        try {
          final state = adapter.editorState;
          await _insertLocal(state);
          final remote = change == 'reorder'
              ? const [
                  CollabEditorBlock(
                    id: 'q',
                    blockType: 'paragraph',
                    text: 'cd',
                  ),
                  CollabEditorBlock(
                    id: 'p',
                    blockType: 'paragraph',
                    text: 'aXb',
                  ),
                ]
              : [
                  CollabEditorBlock(
                    id: 'p',
                    blockType: 'paragraph',
                    text: change == 'text' ? 'ZaXb' : 'aXb',
                    segments: change == 'format'
                        ? const [
                            CollabEditorTextSegment(text: 'aXb', bold: true),
                          ]
                        : const [],
                  ),
                  const CollabEditorBlock(
                    id: 'q',
                    blockType: 'paragraph',
                    text: 'cd',
                  ),
                ];
          await adapter.replaceFromRemote(remote);
          final before = state.document.toJson();
          expect(state.undoManager.undoStack.isEmpty, isTrue);
          state.undoManager.undo();
          await Future<void>.delayed(Duration.zero);
          expect(state.document.toJson(), before);
        } finally {
          adapter.dispose();
        }
      },
    );
  }

  test(
    'remote text invalidates old redo while allowing new local history',
    () async {
      final adapter = _adapter();
      try {
        final state = adapter.editorState;
        await _insertLocal(state);
        state.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        expect(state.undoManager.redoStack.isNonEmpty, isTrue);
        await adapter.replaceFromRemote(const [
          CollabEditorBlock(id: 'p', blockType: 'paragraph', text: 'Zab'),
          CollabEditorBlock(id: 'q', blockType: 'paragraph', text: 'cd'),
        ]);
        expect(state.undoManager.redoStack.isEmpty, isTrue);
        state.undoManager.redo();
        await Future<void>.delayed(Duration.zero);
        expect(adapter.blocks.first.text, 'Zab');
        await state.apply(
          state.transaction..insertText(state.document.first!, 3, '!'),
          skipHistoryDebounce: true,
        );
        state.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        expect(adapter.blocks.first.text, 'Zab');
      } finally {
        adapter.dispose();
      }
    },
  );

  test(
    'stable field history survives reorder after unsafe text entry is removed',
    () async {
      final adapter = _adapter();
      try {
        final state = adapter.editorState;
        await _insertLocal(state);
        state.selection = Selection.single(path: [0], startOffset: 1);
        await setCollabNextParagraphStyle(state, 'same');
        await adapter.replaceFromRemote([
          const CollabEditorBlock(id: 'q', blockType: 'paragraph', text: 'cd'),
          CollabEditorBlock(
            id: 'p',
            blockType: 'paragraph',
            text: 'aXb',
            paragraphStyle: CollabResource.fromValues({
              'nextParagraphStyle': 'same',
            }),
          ),
        ]);
        expect(state.undoManager.undoStack.isNonEmpty, isTrue);
        state.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        expect(adapter.blocks.map((b) => '${b.id}:${b.text}'), [
          'q:cd',
          'p:aXb',
        ]);
        expect(
          adapter.blocks.last.paragraphStyle?.values['nextParagraphStyle'],
          isNull,
        );
        expect(state.undoManager.undoStack.isEmpty, isTrue);
      } finally {
        adapter.dispose();
      }
    },
  );

  test(
    'equivalent authoritative snapshot preserves ordinary local undo',
    () async {
      final adapter = _adapter();
      try {
        final state = adapter.editorState;
        await _insertLocal(state);
        await adapter.replaceFromRemote(adapter.blocks);
        expect(state.undoManager.undoStack.isNonEmpty, isTrue);
        state.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        expect(adapter.blocks.first.text, 'ab');
      } finally {
        adapter.dispose();
      }
    },
  );
}

/// 创建拥有两个段落及编辑器的适配器；调用方负责dispose。
AppFlowyBlockEditorAdapter _adapter() => AppFlowyBlockEditorAdapter(
  initialBlocks: const [
    CollabEditorBlock(id: 'p', blockType: 'paragraph', text: 'ab'),
    CollabEditorBlock(id: 'q', blockType: 'paragraph', text: 'cd'),
  ],
  onLocalBlocksChanged: (_) {},
);

/// 在借用[state]的首段插入X，单独封闭历史项以核对撤销失效边界。
Future<void> _insertLocal(EditorState state) async {
  state.selection = Selection.single(path: [0], startOffset: 1);
  await state.apply(
    state.transaction..insertText(state.document.first!, 1, 'X'),
    skipHistoryDebounce: true,
  );
}
