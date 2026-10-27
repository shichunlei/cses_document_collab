import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/model/collab_user_mention.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 覆盖原生用户提及的公共解析、裸正文历史、宿主保护与实例渲染服务隔离。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('keyboardHeightEventChannel'),
      MockStreamHandler.inline(onListen: (_, events) => events.success(0.0)),
    );
  });

  test('public parser accepts legacy user snapshots and rejects mismatched identities', () {
    final attributes = {
      'cses_inline_mention': '张三',
      'cses_mention_id': 'u1',
      'cses_mention_attributes': jsonEncode({'mentionType': 'user', 'mentionId': 'u1'}),
    };
    final mention = EditorUserMention.read(attributes);
    expect(mention.id, 'u1');
    expect(mention.name, '张三');
    expect(mention.raw, attributes['cses_mention_attributes']);
    expect(EditorUserMention.tryRead({'cses_inline_mention': '旧名', 'cses_mention_id': 'old'})!.raw, isNull);
    for (final invalid in [
      <String, dynamic>{},
      {...attributes, 'cses_mention_type': 'task'},
      {...attributes, 'cses_mention_id': ''},
      {...attributes, 'cses_inline_mention': ' '},
      {...attributes, 'cses_mention_attributes': '[]'},
      {...attributes, 'cses_mention_attributes': '{'},
      {
        ...attributes,
        'cses_mention_attributes': jsonEncode({'mentionId': 'different'}),
      },
      {
        ...attributes,
        'cses_mention_attributes': jsonEncode({'d:mentionType': 'meeting'}),
      },
      {
        ...attributes,
        'cses_mention_attributes': jsonEncode({'mentionId': 'u1', 'd:mentionId': 'other'}),
      },
      {...attributes, 'cses_mention_attributes': 'x' * 32769},
    ]) {
      expect(() => EditorUserMention.read(invalid), throwsFormatException);
      expect(EditorUserMention.tryRead(invalid), isNull);
    }
    expect(EditorUserMention.attributeKeys, hasLength(4));
  });

  test('public factory produces the same native user atom as editor insertion', () async {
    const user = CollabMentionUser(id: 'u1', name: '张三', department: '研发', avatarUrl: 'private-avatar');
    final delta = EditorUserMention.createDelta(user);
    expect(delta.toPlainText(), '\uFFFC ');
    final atom = delta.whereType<TextInsert>().first;
    expect(EditorUserMention.read(atom.attributes!).id, 'u1');
    expect(jsonDecode(atom.attributes!['cses_mention_attributes'] as String), {
      'mentionType': 'user',
      'mentionId': 'u1',
    });
    expect(jsonEncode(delta.toJson()), isNot(contains('private-avatar')));
    expect(jsonEncode(delta.toJson()), isNot(contains('研发')));
    final editor = DocumentEditorController(
      document: Document(
        root: Node(type: 'page', children: [paragraphNode()]),
      ),
      commandContext: const EditorCommandContext(localOnly: true),
    );
    final state = editor.editorState;
    try {
      final selection = Selection.collapsed(Position(path: [0]));
      await insertCollabUserMention(state, selection, user);
      expect(state.getNodeAtPath([0])!.delta!.toJson(), delta.toJson());
      delta.insert('改变');
      expect(EditorUserMention.createDelta(user).toPlainText(), '\uFFFC ');
    } finally {
      await editor.close();
    }
    for (final invalid in const [CollabMentionUser(id: ' ', name: '张三'), CollabMentionUser(id: 'u1', name: ' ')]) {
      expect(() => EditorUserMention.createDelta(invalid), throwsArgumentError);
    }
  });

  for (final localOnly in [false, true]) {
    test('bare document inserts and undoes native user atoms localOnly=$localOnly', () async {
      final editor = DocumentEditorController(
        document: Document(
          root: Node(
            type: 'page',
            children: [paragraphNode(text: '前😀后')],
          ),
        ),
        commandContext: EditorCommandContext(localOnly: localOnly),
      );
      addTearDown(editor.close);
      final state = editor.editorState;
      final selection = Selection.single(path: [0], startOffset: 1, endOffset: 3);
      state.selection = selection;
      final landing = await insertCollabUserMention(state, selection, const CollabMentionUser(id: 'u1', name: '张三'));
      expect(landing!.start.offset, 3);
      expect(state.document.first!.delta!.toPlainText(), '前\uFFFC 后');
      expect(EditorUserMention.read(state.document.first!.delta!.slice(1, 2).first.attributes!).id, 'u1');
      state.undoManager.undo();
      await pumpEventQueue();
      expect(state.document.first!.delta!.toPlainText(), '前😀后');
      state.undoManager.redo();
      await pumpEventQueue();
      expect(state.document.first!.delta!.toPlainText(), '前\uFFFC 后');
      if (localOnly) {
        expect(state.document.first!.attributes.containsKey('cses_inline_formula_command'), isFalse);
      }
    });
  }

  test('local user insertion exposes the actual atom to the first host guard', () async {
    final editor = DocumentEditorController(
      document: Document(
        root: Node(
          type: 'page',
          children: [paragraphNode(text: '原文')],
        ),
      ),
      commandContext: const EditorCommandContext(localOnly: true),
    );
    addTearDown(editor.close);
    final state = editor.editorState;
    var checkedAtom = false;
    state.transactionGuard = (transaction) {
      final operation = transaction.operations.single;
      expect(operation, isA<UpdateTextOperation>());
      checkedAtom = (operation as UpdateTextOperation).delta.whereType<TextInsert>().any(
        (run) => EditorUserMention.tryRead(run.attributes)?.id == 'u1',
      );
      return false;
    };
    final result = await insertCollabUserMention(
      state,
      Selection.single(path: [0], startOffset: 1),
      const CollabMentionUser(id: 'u1', name: '张三'),
    );
    expect(result, isNull);
    expect(checkedAtom, isTrue);
    expect(state.document.first!.delta!.toPlainText(), '原文');
    expect(state.undoManager.undoStack, isEmpty);
  });

  test('rejected replacement of the same existing user is not reported as inserted', () async {
    final original = Delta()
      ..insert('\uFFFC', attributes: {'cses_inline_mention': '张三', 'cses_mention_id': 'u1'})
      ..insert('后续原文');
    final editor = DocumentEditorController(
      document: Document(
        root: Node(
          type: 'page',
          children: [paragraphNode(delta: original)],
        ),
      ),
      commandContext: const EditorCommandContext(localOnly: true),
    );
    addTearDown(editor.close);
    editor.editorState.transactionGuard = (_) => false;
    final result = await insertCollabUserMention(
      editor.editorState,
      Selection.single(path: [0], startOffset: 0, endOffset: 1),
      const CollabMentionUser(id: 'u1', name: '张三'),
    );
    expect(result, isNull);
    expect(editor.editorState.document.first!.delta, original);
    expect(editor.editorState.undoManager.undoStack, isEmpty);
  });

  testWidgets('native picker preserves local undo redo caret and input connection', (tester) async {
    final editor = await _mountMentionEditor(tester);
    final state = editor.editorState;
    final source = Selection.single(path: [0], startOffset: 1);
    await _setCaret(tester, state, source);
    final action = showEditorUserMention(tester.element(find.byType(DocumentEditorView)), state);
    await tester.pumpAndSettle();
    expect(state.selection, isNull);
    await tester.tap(find.byKey(const ValueKey('native-mention-user')));
    await tester.pumpAndSettle();
    await _finish(tester, action);
    expect(state.document.first!.delta!.toPlainText(), '前\uFFFC 后');
    final landing = Selection.single(path: [0], startOffset: 3);
    expect(state.selection, landing);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    state.undoManager.undo();
    await tester.pumpAndSettle();
    expect(state.document.first!.delta!.toPlainText(), '前后');
    expect(state.selection, source);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    state.undoManager.redo();
    await tester.pumpAndSettle();
    expect(state.document.first!.delta!.toPlainText(), '前\uFFFC 后');
    expect(state.selection, landing);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(editor.close);
  });

  testWidgets('bold paragraph at trigger opens the native picker with inherited format', (tester) async {
    final editor = await _mountMentionEditor(tester, bold: true);
    final state = editor.editorState;
    await _setCaret(tester, state, Selection.single(path: [0], startOffset: 1));
    final action = handleEditorUserMentionTrigger(tester.element(find.byType(DocumentEditorView)), state);
    await tester.pumpAndSettle();
    expect(state.document.first!.delta!.toPlainText(), '前@后');
    expect(state.document.first!.delta!.slice(1, 2).first.attributes?[AppFlowyRichTextKeys.bold], isTrue);
    expect(find.byKey(const ValueKey('native-mention-user')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('native-mention-user')));
    await tester.pumpAndSettle();
    expect(await _finish(tester, action), isTrue);
    expect(state.document.first!.delta!.toPlainText(), '前\uFFFC 后');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(editor.close);
  });

  testWidgets('public decorator uses only the local instance avatar service', (tester) async {
    final owner = Object();
    var leakedAvatarCalls = 0;
    CollabRuntime.acquire(
      owner,
      CollabHostServices(
        mentionAvatarBuilder: (_, {required userId, required name, required size, avatarUrl}) {
          leakedAvatarCalls++;
          return const Text('其他文档头像');
        },
      ),
    );
    addTearDown(() => CollabRuntime.release(owner));
    final editor = DocumentEditorController(
      document: Document(
        root: Node(type: 'page', children: [paragraphNode()]),
      ),
      commandContext: const EditorCommandContext(localOnly: true),
    );
    final node = editor.editorState.document.first!;
    final run = TextInsert('\uFFFC', attributes: {'cses_inline_mention': '本地用户', 'cses_mention_id': 'local'});
    await tester.pumpWidget(
      MaterialApp(
        home: Provider<EditorState>.value(
          value: editor.editorState,
          child: Builder(
            builder: (context) => Text.rich(
              decorateEditorUserMention(
                context,
                node,
                0,
                run,
                const TextSpan(style: TextStyle(fontSize: 16)),
                const TextSpan(style: TextStyle(fontSize: 16)),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('本地用户'), findsOneWidget);
    expect(find.text('其他文档头像'), findsNothing);
    expect(leakedAvatarCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(editor.close);
  });

  testWidgets('native at trigger consumes a rejected write without opening a picker', (tester) async {
    var picks = 0;
    final editor = DocumentEditorController(
      commandContext: EditorCommandContext(
        localOnly: true,
        configuration: EditorConfiguration(inlineFormats: const {EditorInlineFormat.mention}),
        services: CollabHostServices(
          pickMentionUser: (_, {required keyword, required canEdit}) async {
            picks++;
            return null;
          },
        ),
      ),
    );
    editor.editorState.selection = Selection.single(path: [0], startOffset: 0);
    editor.editorState.transactionGuard = (_) => false;
    late BuildContext triggerContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            triggerContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(await handleEditorUserMentionTrigger(triggerContext, editor.editorState), isTrue);
    expect(editor.editorState.document.first!.delta!.toPlainText(), isEmpty);
    expect(picks, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(editor.close);
  });
}

/// 在[tester]中挂载不连接原生引擎的正文，按[bold]选择初始字符格式。
Future<DocumentEditorController> _mountMentionEditor(WidgetTester tester, {bool bold = false}) async {
  final delta = Delta()..insert('前后', attributes: bold ? {AppFlowyRichTextKeys.bold: true} : null);
  final editor = DocumentEditorController(
    document: Document(
      root: Node(
        type: 'page',
        children: [paragraphNode(delta: delta)],
      ),
    ),
    commandContext: EditorCommandContext(
      localOnly: true,
      configuration: EditorConfiguration(
        inlineFormats: const {EditorInlineFormat.mention, EditorInlineFormat.bold},
        keyboardToolbarItems: const [EditorKeyboardToolbarItem.mention],
      ),
      services: CollabHostServices(pickMentionUser: _pickUser),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [AppFlowyEditorLocalizations.delegate],
      home: Scaffold(body: DocumentEditorView(editorState: editor.editorState)),
    ),
  );
  await tester.pumpAndSettle();
  return editor;
}

/// 在借用[context]中选择单个用户，等待路由退场；[keyword]仅供契约，[canEdit]限制确认。
Future<CollabMentionUser?> _pickUser(
  BuildContext context, {
  required String keyword,
  required ValueListenable<bool> canEdit,
}) async {
  ModalRoute<CollabMentionUser>? route;
  final result = await showModalBottomSheet<CollabMentionUser>(
    context: context,
    builder: (context) {
      route = ModalRoute.of(context);
      return TextButton(
        key: const ValueKey('native-mention-user'),
        onPressed: () =>
            Navigator.of(context).pop(canEdit.value ? const CollabMentionUser(id: 'u1', name: '张三') : null),
        child: const Text('张三'),
      );
    },
  );
  await route?.completed;
  return result;
}

/// 为借用[state]恢复[selection]并推进[tester]的真实移动输入连接。
Future<void> _setCaret(WidgetTester tester, EditorState state, Selection selection) async {
  final update = state.updateSelectionWithReason(selection, reason: SelectionUpdateReason.uiEvent);
  await tester.pump();
  await update;
  await tester.pump(const Duration(milliseconds: 150));
}

/// 推进[tester]中的模态退场与键盘恢复，然后返回[future]的结果。
Future<T> _finish<T>(WidgetTester tester, Future<T> future) async {
  var completed = false;
  final result = future.then((value) {
    completed = true;
    return value;
  });
  for (var i = 0; i < 12 && !completed; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(completed, isTrue);
  return result;
}
