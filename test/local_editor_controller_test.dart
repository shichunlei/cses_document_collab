import 'package:cses_document_collab/src/editor/core/editor_configuration.dart';
import 'dart:async';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/local_editor_controller.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_editing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

/// 无原生初始化的本地输入、历史、粘贴和隔离回归。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'clipboard cut waits for system success and is independently undoable',
    () async {
      String? copied;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      final local = LocalEditorController(initialText: 'before after');
      try {
        local.editorState.selection = Selection.single(
          path: [0],
          startOffset: 0,
          endOffset: 6,
        );
        await local.copyText(cut: true);
        expect(copied, 'before');
        expect(
          local.editorState.document.root.children.single.delta!.toPlainText(),
          ' after',
        );
        local.editorState.undoManager.undo();
        expect(
          local.editorState.document.root.children.single.delta!.toPlainText(),
          'before after',
        );
      } finally {
        await local.close();
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      }
    },
  );

  test('late clipboard success never cuts a changed document', () async {
    final written = Completer<void>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') await written.future;
      return null;
    });
    final local = LocalEditorController(initialText: 'keep');
    try {
      final state = local.editorState;
      state.selection = Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 4,
      );
      final pending = local.copyText(cut: true);
      final failure = expectLater(pending, throwsStateError);
      await state.apply(
        state.transaction
          ..insertText(state.document.root.children.single, 4, '!'),
      );
      written.complete();
      await failure;
      expect(state.document.root.children.single.delta!.toPlainText(), 'keep!');
    } finally {
      if (!written.isCompleted) written.complete();
      await local.close();
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    }
  });

  test(
    'local sessions preserve independent input, formatting and history',
    () async {
      final first = LocalEditorController(initialText: 'Hello');
      final second = LocalEditorController(initialText: 'Other');
      try {
        final state = first.editorState;
        state.selection = Selection.single(
          path: [0],
          startOffset: 1,
          endOffset: 4,
        );
        await first.format({'t:px': 32, AppFlowyRichTextKeys.bold: true});
        expect(
          state.document.root.children.single.delta!
              .slice(1, 4)
              .first
              .attributes?['t:px'],
          32,
        );
        state.undoManager.undo();
        expect(
          state.document.root.children.single.delta!.toPlainText(),
          'Hello',
        );
        expect(
          state.document.root.children.single.delta!.first.attributes?['t:px'],
          isNull,
        );
        state.undoManager.redo();
        expect(
          state.document.root.children.single.delta!
              .slice(1, 4)
              .first
              .attributes?['t:px'],
          32,
        );
        expect(
          second.editorState.document.root.children.single.delta!.toPlainText(),
          'Other',
        );
        await first.close();
        expect(second.editorState.isDisposed, isFalse);
        await second.editorState.apply(
          second.editorState.transaction..insertText(
            second.editorState.document.root.children.single,
            5,
            '!',
          ),
        );
        expect(
          second.editorState.document.root.children.single.delta!.toPlainText(),
          'Other!',
        );
      } finally {
        await first.close();
        await second.close();
      }
    },
  );

  test(
    'empty paragraph typing style survives input and paragraph Enter',
    () async {
      final local = LocalEditorController();
      try {
        final state = local.editorState;
        state.selection = Selection.collapsed(Position(path: [0]));
        await local.format({'t:px': 24});
        expect(state.toggledStyle['t:px'], 24);
        await state.apply(
          state.transaction
            ..insertText(
              state.document.root.children.single,
              0,
              '中文',
              attributes: state.toggledStyle,
            )
            ..afterSelection = Selection.collapsed(
              Position(path: [0], offset: 2),
            ),
        );
        expect(
          state.document.root.children.single.delta!.first.attributes?['t:px'],
          24,
        );
        expect(await handleCollabParagraphEnter(state), isTrue);
        expect(state.document.root.children.length, 2);
        expect(state.document.root.children.first.delta!.toPlainText(), '中文');
        expect(state.toggledStyle['t:px'], 24);
      } finally {
        await local.close();
      }
    },
  );

  test(
    'plain paste replaces a multi paragraph range atomically and keeps literal syntax',
    () async {
      final local = LocalEditorController(initialText: 'before\nafter');
      try {
        final state = local.editorState;
        state.selection = Selection(
          start: Position(path: [0], offset: 2),
          end: Position(path: [1], offset: 3),
        );
        await local.pasteText('# literal\nhttps://example.com');
        expect(
          state.document.root.children.map((n) => n.delta!.toPlainText()),
          ['be# literal', 'https://example.comer'],
        );
        expect(
          state.document.root.children.every((n) => n.type == 'paragraph'),
          isTrue,
        );
        expect(
          state
              .document
              .root
              .children
              .last
              .delta!
              .first
              .attributes?[AppFlowyRichTextKeys.href],
          isNull,
        );
        state.undoManager.undo();
        expect(
          state.document.root.children.map((n) => n.delta!.toPlainText()),
          ['before', 'after'],
        );
        state.undoManager.redo();
        expect(
          state.document.root.children.last.delta!.toPlainText(),
          'https://example.comer',
        );
      } finally {
        await local.close();
      }
    },
  );

  test(
    'block conversion and undo retain text, and unsupported insert is rejected',
    () async {
      final local = LocalEditorController(
        initialText: 'Title',
        configuration: EditorConfiguration.text,
      );
      try {
        final state = local.editorState;
        state.selection = Selection.collapsed(Position(path: [0], offset: 2));
        await local.convert('heading', level: 2);
        expect(state.document.root.children.single.type, 'heading');
        expect(
          state.document.root.children.single.delta!.toPlainText(),
          'Title',
        );
        state.undoManager.undo();
        expect(state.document.root.children.single.type, 'paragraph');
        final revision = local.revision;
        await state.apply(
          state.transaction..insertNode(
            [1],
            Node(
              type: 'image',
              attributes: {'url': 'https://example.com/a.png'},
            ),
          ),
        );
        expect(local.revision, revision);
        expect(state.document.root.children.length, 1);
        await expectLater(local.pasteText('x' * 100001), throwsStateError);
      } finally {
        await local.close();
      }
    },
  );
}
