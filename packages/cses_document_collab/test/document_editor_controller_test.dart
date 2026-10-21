import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证无原生初始化的编辑、可选同步绑定、事务顺序及会话服务隔离。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'borrowed editor outlives synchronization and remote never echoes',
    () async {
      final editor = DocumentEditorController();
      addTearDown(editor.close);
      final published = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        editing: editor,
        onLocalBlocksChanged: published.add,
      );
      final state = editor.editorState;
      expect(identical(adapter.editorState, state), isTrue);
      await state.apply(
        state.transaction
          ..insertText(state.document.root.children.single, 0, 'Local'),
      );
      expect(published, hasLength(1));
      expect(editor.revision, 1);
      await adapter.replaceFromRemote([
        CollabEditorBlock(
          id: published.single.single.id,
          blockType: 'paragraph',
          text: 'Remote',
        ),
      ]);
      expect(published, hasLength(1));
      expect(editor.revision, 1);
      expect(
        state.document.root.children.single.delta!.toPlainText(),
        'Remote',
      );
      adapter.dispose();
      expect(state.isDisposed, isFalse);
      await state.apply(
        state.transaction
          ..insertText(state.document.root.children.single, 6, '!'),
      );
      expect(
        state.document.root.children.single.delta!.toPlainText(),
        'Remote!',
      );
      expect(published, hasLength(1));
      await editor.close();
      expect(state.isDisposed, isTrue);
    },
  );
  test('transaction hook ordering and duplicate binding protection', () async {
    final editor = DocumentEditorController();
    addTearDown(editor.close);
    final calls = <String>[];
    final binding = EditorSynchronizationBinding(
      prepare: (_) => calls.add('prepare'),
      validate: (_) => calls.add('validate'),
      didApply: (_) => calls.add('publish'),
    );
    editor.attachSynchronization(binding);
    expect(() => editor.attachSynchronization(binding), throwsStateError);
    await editor.editorState.apply(
      editor.editorState.transaction
        ..insertText(editor.editorState.document.root.children.single, 0, '正文'),
    );
    expect(calls, ['prepare', 'validate', 'publish']);
    editor.detachSynchronization(const EditorSynchronizationBinding());
    expect(() => editor.attachSynchronization(binding), throwsStateError);
    editor.detachSynchronization(binding);
    editor.attachSynchronization(binding);
    editor.detachSynchronization(binding);
  });
  test('local services never inherit the active native host', () async {
    final owner = Object();
    var hostErrors = 0;
    final services = CollabHostServices(onError: (_, _, _, _) => hostErrors++);
    CollabRuntime.acquire(owner, services);
    addTearDown(() => CollabRuntime.release(owner));
    final editor = DocumentEditorController();
    final image = LocalEditorController(initialText: 'Text');
    try {
      expect(identical(editor.commandContext.services, services), isFalse);
      expect(identical(image.commandContext.services, services), isFalse);
      expect(
        image.commandContext.configuration,
        same(EditorConfiguration.local),
      );
      expect(image.commandContext.localOnly, isTrue);
      await image.close();
      expect(identical(image.commandContext.services, services), isFalse);
      expect(editor.editorState.isDisposed, isFalse);
      expect(CollabRuntime.owns(owner), isTrue);
      expect(hostErrors, 0);
    } finally {
      await image.close();
      await editor.close();
    }
  });
  test(
    'image guard rejects unsupported content and retained styles atomically',
    () async {
      final image = LocalEditorController(
        initialText: 'Text',
        configuration: EditorConfiguration.text,
      );
      addTearDown(image.close);
      final state = image.editorState;
      final node = state.document.root.children.single;
      await state.apply(
        state.transaction..insertNode(
          [1],
          paragraphNode(text: 'bad')
            ..updateAttributes({HeadingBlockKeys.level: 9}),
        ),
      );
      expect(state.document.root.children, hasLength(1));
      await state.apply(
        state.transaction..formatText(node, 0, 4, {'cses_superscript': true}),
      );
      expect(node.delta!.first.attributes?['cses_superscript'], isNull);
      await state.apply(
        state.transaction
          ..updateNode(node, {blockComponentAlign: 'distributed'}),
      );
      expect(node.attributes[blockComponentAlign], isNull);
      expect(node.delta!.toPlainText(), 'Text');
    },
  );
}
