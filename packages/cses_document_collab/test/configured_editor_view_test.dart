import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// [state]为借用会话；[skin]为展示扩展，[editable]/[preview]使用相同交互规则。
Widget _app(
  EditorState state, {
  EditorViewConfiguration skin = EditorViewConfiguration.standard,
  bool editable = true,
  bool preview = false,
  EditorScrollController? scroll,
}) => MaterialApp(
  localizationsDelegates: const [AppFlowyEditorLocalizations.delegate],
  home: Scaffold(
    body: DocumentEditorView(
      editorState: state,
      configuration: skin,
      editable: editable,
      preview: preview,
      scrollController: scroll,
    ),
  ),
);

/// 从[tester]借用唯一原生文字视图，检查实际装配。
AppFlowyEditor _editor(WidgetTester tester) => tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));

/// 在[tester]中卸载视图后关闭[document]，允许根事件循环完成订阅注销。
Future<void> _close(WidgetTester tester, DocumentEditorController document) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  await tester.runAsync(document.close);
}

/// 同一能力配置对比本地与协同上下文；测试会话不挂载任何网络绑定。
void main() {
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('keyboardHeightEventChannel'),
      MockStreamHandler.inline(onListen: (_, events) => events.success(0.0)),
    );
  });
  test('view extension collections are immutable copies', () {
    final shortcuts = <CharacterShortcutEvent>[];
    final actions = <EditorKeyboardAction>[];
    final skin = EditorViewConfiguration(characterShortcuts: shortcuts, keyboardActions: actions);
    shortcuts.add(CharacterShortcutEvent(key: 'later', character: '~', handler: (_) async => false));
    expect(skin.characterShortcuts, isEmpty);
    expect(() => skin.characterShortcuts.clear(), throwsUnsupportedError);
    expect(() => skin.keyboardActions.clear(), throwsUnsupportedError);
  });
  testWidgets('local and collaborative contexts share menus and transactions', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final config = EditorConfiguration(
      blocks: [EditorBlock.paragraph, EditorBlock.heading, EditorBlock.bulletedList, EditorBlock.todoList],
      headingLevels: {1, 2, 3, 4, 5, 6},
      blockConversionPreservedAttributes: {'host_tag'},
      keyboardToolbarItems: [
        EditorKeyboardToolbarItem.blockType,
        EditorKeyboardToolbarItem.textStyle,
        EditorKeyboardToolbarItem.blockLayout,
      ],
    );
    List<String>? commands;
    List<String>? characters;
    Map<String, dynamic>? result;
    for (final local in [true, false]) {
      var copied = 0;
      final document = DocumentEditorController(
        document: Document(
          root: Node(
            type: 'page',
            children: [
              paragraphNode(
                text: 'Alpha',
                attributes: {'host_tag': 'preserved', blockComponentTextDirection: 'rtl', blockComponentAlign: 'right'},
              ),
            ],
          ),
        ),
        commandContext: EditorCommandContext(
          configuration: config,
          localOnly: local,
          copySelection: (selection, {required cut}) async {
            copied++;
          },
        ),
      );
      final state = document.editorState;
      try {
        await tester.pumpWidget(_app(state));
        await tester.pumpAndSettle();
        state.selection = Selection.single(path: [0], startOffset: 0, endOffset: 5);
        await tester.pumpAndSettle();
        final view = _editor(tester);
        final nextCommands = view.commandShortcutEvents.map((e) => e.key).toList();
        final nextCharacters = view.characterShortcutEvents.map((e) => e.key).toList();
        if (commands != null) expect(nextCommands, commands);
        if (characters != null) expect(nextCharacters, characters);
        commands = nextCommands;
        characters = nextCharacters;
        expect(nextCommands.where((key) => key == copyCommand.key || key == cutCommand.key), isEmpty);
        expect(
          view.commandShortcutEvents.singleWhere((e) => e.key == 'document-editor-copy').handler(state),
          KeyEventResult.handled,
        );
        await tester.pumpAndSettle();
        expect(copied, 1);
        await tester.tap(find.byTooltip('块类型'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('editor-block-heading-4')), findsNothing);
        for (var level = 3; level <= 5; level++) {
          final button = find.byKey(ValueKey('editor-block-heading-$level'));
          await tester.ensureVisible(button);
          await tester.tap(button);
          await tester.pumpAndSettle();
          expect(find.byKey(ValueKey('editor-block-heading-${level + 1}')), findsOneWidget);
        }
        final keyboard = _editor(tester).commandShortcutEvents.singleWhere((e) => e.key == 'toggle into Heading 3');
        expect(keyboard.handler(state), KeyEventResult.handled);
        await tester.pumpAndSettle();
        expect(state.document.first!.attributes['level'], 3);
        expect(state.document.first!.attributes['host_tag'], 'preserved');
        expect(state.document.first!.attributes[blockComponentTextDirection], 'rtl');
        expect(state.document.first!.attributes[blockComponentAlign], 'right');
        expect(keyboard.handler(state), KeyEventResult.handled);
        await tester.pumpAndSettle();
        expect(state.document.first!.type, ParagraphBlockKeys.type);
        await state.apply(
          state.transaction
            ..updateNode(state.document.first!, {blockComponentDelta: (Delta()..insert('###')).toJson()}),
        );
        state.selection = Selection.collapsed(Position(path: [0], offset: 3));
        final markdown = _editor(tester).characterShortcutEvents.singleWhere((e) => e.key == 'editor-heading-markdown');
        expect(await markdown.handler(state), isTrue);
        await tester.pumpAndSettle();
        final node = state.document.first!;
        expect(node.type, HeadingBlockKeys.type);
        expect(node.attributes['level'], 3);
        expect(node.attributes['host_tag'], 'preserved');
        final next = {
          'type': node.type,
          'level': node.attributes['level'],
          'tag': node.attributes['host_tag'],
          'align': node.attributes[blockComponentAlign],
          'direction': node.attributes[blockComponentTextDirection],
          'delta': node.delta!.toJson(),
        };
        if (result != null) expect(next, result);
        result = next;
        expect(tester.takeException(), isNull);
      } finally {
        await _close(tester, document);
      }
    }
  });
  testWidgets('progressive headings skip disabled levels without hiding enabled commands', (tester) async {
    final document = DocumentEditorController(
      commandContext: EditorCommandContext(
        configuration: EditorConfiguration(
          blocks: [EditorBlock.paragraph, EditorBlock.heading],
          headingLevels: {1, 3, 6},
          keyboardToolbarItems: [EditorKeyboardToolbarItem.blockType],
        ),
        localOnly: true,
      ),
    );
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    try {
      await tester.pumpWidget(_app(document.editorState));
      await tester.pumpAndSettle();
      document.editorState.selection = Selection.collapsed(Position(path: [0]));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('块类型'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-block-heading-6')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('editor-block-heading-3')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-block-heading-6')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('editor-block-heading-6')));
      await tester.pumpAndSettle();
      expect(document.editorState.document.first!.attributes['level'], 6);
      expect(_editor(tester).commandShortcutEvents.any((event) => event.key == 'toggle into Heading 2'), isFalse);
    } finally {
      await _close(tester, document);
    }
  });
  for (final local in [true, false]) {
    testWidgets('read-only and preview share rules local=$local', (tester) async {
      final document = DocumentEditorController(
        commandContext: EditorCommandContext(
          configuration: EditorConfiguration(blocks: [EditorBlock.paragraph]),
          localOnly: local,
        ),
      );
      try {
        await tester.pumpWidget(_app(document.editorState, editable: false));
        await tester.pumpAndSettle();
        expect(_editor(tester).editable, isFalse);
        expect(_editor(tester).disableSelectionService, isFalse);
        final shell = tester.widget<EditorInteractionShell>(find.byType(EditorInteractionShell));
        expect(shell.enabled, isTrue);
        expect(shell.editable, isFalse);
        await tester.pumpWidget(_app(document.editorState, preview: true));
        await tester.pumpAndSettle();
        expect(_editor(tester).disableSelectionService, isTrue);
        expect(_editor(tester).disableKeyboardService, isTrue);
        expect(tester.widget<EditorInteractionShell>(find.byType(EditorInteractionShell)).enabled, isFalse);
      } finally {
        await _close(tester, document);
      }
    });
  }
  testWidgets('skin update preserves borrowed scroll, document and history', (tester) async {
    final document = DocumentEditorController();
    final state = document.editorState;
    final scroll = EditorScrollController(editorState: state);
    var configured = 0;
    try {
      await tester.pumpWidget(_app(state, scroll: scroll));
      await tester.pumpAndSettle();
      await state.apply(state.transaction..insertText(state.document.first!, 0, 'Kept'));
      final snapshot = state.document.toJson();
      final history = state.undoManager.undoStack.last;
      final skin = EditorViewConfiguration(
        blockBuilders: (builders) {
          configured++;
          return builders;
        },
        style: (context, style) => style.copyWith(cursorColor: Colors.brown),
      );
      await tester.pumpWidget(_app(state, scroll: scroll, skin: skin));
      await tester.pumpAndSettle();
      expect(configured, 1);
      expect(_editor(tester).editorScrollController, same(scroll));
      expect(state.document.toJson(), snapshot);
      expect(state.undoManager.undoStack.last, same(history));
      expect(_editor(tester).editorStyle.cursorColor, Colors.brown);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      scroll.dispose();
      await tester.runAsync(document.close);
    }
  });
}
