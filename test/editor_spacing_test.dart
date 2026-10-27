import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/core/document_editor_controller.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/editor/core/editor_configuration.dart';
import 'package:cses_document_collab/src/editor/document_editor_view.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_text_style.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 在[tester]中滚动[menu]直至[action]可点击，再等待菜单/事务结束。
Future<void> _tap(WidgetTester tester, String menu, String action) async {
  final target = find.byKey(ValueKey(action));
  if (target.evaluate().isNotEmpty) {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }
  for (final direction in [-1.0, 1.0]) {
    for (var i = 0; i < 12 && target.hitTestable().evaluate().isEmpty; i++) {
      await tester.drag(find.byKey(ValueKey(menu)), Offset(direction * 120, 0));
      await tester.pumpAndSettle();
    }
  }
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// 通过真实公共界面及事务验证两类间距，不用菜单实现的内部状态作为结果。
void main() {
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('keyboardHeightEventChannel'),
      MockStreamHandler.inline(onListen: (_, events) => events.success(0.0)),
    );
  });
  for (final local in [true, false]) {
    for (final line in [true, false]) {
      testWidgets('spacing applies resets undo and revocation local=$local line=$line', (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        final controller = DocumentEditorController(
          document: Document(
            root: Node(
              type: 'page',
              children: [
                paragraphNode(text: 'Alpha'),
                paragraphNode(text: 'Beta'),
              ],
            ),
          ),
          commandContext: EditorCommandContext(
            configuration: local ? EditorConfiguration.local : EditorConfiguration.document,
            localOnly: local,
          ),
        );
        final state = controller.editorState;
        final prefix = line ? 'editor-line-height' : 'editor-letter-spacing';
        final value = line ? 2.0 : .1;
        try {
          await tester.pumpWidget(
            MaterialApp(
              localizationsDelegates: const [AppFlowyEditorLocalizations.delegate],
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: Scaffold(body: DocumentEditorView(editorState: state)),
            ),
          );
          state.selection = Selection(
            start: Position(path: [0]),
            end: Position(path: [1], offset: 4),
          );
          await tester.pumpAndSettle();
          await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
          await tester.tap(
            find.byKey(ValueKey(line ? 'editor-shortcut-block-layout' : 'editor-shortcut-inline-style')),
          );
          await tester.pumpAndSettle();
          await _tap(
            tester,
            line ? 'editor-block-layout-menu' : 'editor-inline-style-menu',
            line ? 'editor-block-line-height' : 'editor-inline-letter-spacing',
          );
          expect(tester.widget<Semantics>(find.byKey(ValueKey('$prefix-default'))).properties.selected, isTrue);
          await _tap(tester, '$prefix-menu', '$prefix-$value');
          for (final node in state.document.root.children) {
            final style = collabParagraphTextStyle(
              node,
              const TextStyle(fontSize: 20, height: 1.5),
              node.delta!.first.attributes ?? {},
            );
            if (line) {
              expect(readCollabParagraph(node).values['lh'], 2);
              expect(style.height, 2);
            } else {
              expect(node.delta!.first.attributes?['t:ls'], .1);
              expect(style.letterSpacing, 2);
            }
          }
          expect(tester.widget<Semantics>(find.byKey(ValueKey('$prefix-$value'))).properties.selected, isTrue);
          expect(find.byKey(ValueKey('$prefix-default')).hitTestable(), findsOneWidget);
          expect(tester.testTextInput.isVisible, isTrue);
          await tester.tap(find.byKey(ValueKey('$prefix-default')));
          await tester.pumpAndSettle();
          for (final node in state.document.root.children) {
            expect(line ? readCollabParagraph(node).values['lh'] : node.delta!.first.attributes?['t:ls'], isNull);
          }
          state.undoManager.undo();
          await tester.pumpAndSettle();
          expect(tester.widget<Semantics>(find.byKey(ValueKey('$prefix-$value'))).properties.selected, isTrue);
          state.undoManager.redo();
          await tester.pumpAndSettle();
          expect(tester.widget<Semantics>(find.byKey(ValueKey('$prefix-default'))).properties.selected, isTrue);
          state.editable = false;
          state.editable = true;
          await _tap(tester, '$prefix-menu', '$prefix-$value');
          expect(tester.widget<Semantics>(find.byKey(ValueKey('$prefix-$value'))).properties.enabled, isFalse);
          expect(
            line
                ? readCollabParagraph(state.document.first!).values['lh']
                : state.document.first!.delta!.first.attributes?['t:ls'],
            isNull,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(controller.close);
        }
      });
    }
  }

  testWidgets('expanded character spacing handles mixed legacy and live caret', (tester) async {
    final controller = DocumentEditorController(
      document: Document(
        root: Node(
          type: 'page',
          children: [
            Node(
              type: ParagraphBlockKeys.type,
              attributes: {
                blockComponentDelta:
                    (Delta()
                          ..insert('A', attributes: {'s:letterSpacing': '0.1em', AppFlowyRichTextKeys.bold: true})
                          ..insert('B', attributes: {'t:ls': .2}))
                        .toJson(),
              },
            ),
          ],
        ),
      ),
    );
    final state = controller.editorState;
    state.selection = Selection.single(path: [0], startOffset: 0, endOffset: 2);
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [AppFlowyEditorLocalizations.delegate],
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => showEditorSelectionFormats(context, state),
                child: const Text('Formats'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Formats'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('editor-inline-letter-spacing')));
      await tester.tap(find.byKey(const ValueKey('editor-inline-letter-spacing')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Semantics>(find.byKey(const ValueKey('editor-letter-spacing-default'))).properties.selected,
        isFalse,
      );
      await _tap(tester, 'editor-letter-spacing-menu', 'editor-letter-spacing--0.1');
      expect(
        state.document.first!.delta!.everyAttributes((a) => a['t:ls'] == -.1 && a['s:letterSpacing'] == null),
        isTrue,
      );
      expect(state.document.first!.delta!.first.attributes?[AppFlowyRichTextKeys.bold], isTrue);
      await tester.tap(find.byKey(const ValueKey('editor-letter-spacing-default')));
      await tester.pumpAndSettle();
      expect(
        state.document.first!.delta!.every(
          (run) => run.attributes?['t:ls'] == null && run.attributes?['s:letterSpacing'] == null,
        ),
        isTrue,
      );
      expect(readCollabParagraph(state.document.first!).values['textDefaults'], isNull);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      // A separate live editor tests pending caret attributes without the sheet's saved range.
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [AppFlowyEditorLocalizations.delegate],
          home: Scaffold(body: DocumentEditorView(editorState: state)),
        ),
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetViewInsets);
      state.selection = Selection.collapsed(Position(path: [0], offset: 2));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-shortcut-inline-style')));
      await tester.pumpAndSettle();
      await _tap(tester, 'editor-inline-style-menu', 'editor-inline-letter-spacing');
      await _tap(tester, 'editor-letter-spacing-menu', 'editor-letter-spacing-0.1');
      expect(state.toggledStyle['t:ls'], .1);
      await state.apply(state.transaction..insertText(state.document.first!, 2, 'C', attributes: state.toggledStyle));
      await tester.pumpAndSettle();
      expect(state.document.first!.delta!.last.attributes?['t:ls'], .1);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(controller.close);
    }
  });

  test('line height alone exposes the layout toolbar', () {
    for (final enabled in [true, false]) {
      expect(
        EditorConfiguration(
          blocks: [EditorBlock.paragraph],
          inlineFormats: {},
          alignments: {},
          nextParagraphStyle: false,
          lineHeight: enabled,
        ).hasLayout,
        enabled,
      );
    }
  });

  testWidgets('spacing controls respect explicit disabled configuration', (tester) async {
    final controller = DocumentEditorController(
      document: Document(
        root: Node(
          type: 'page',
          children: [paragraphNode(text: 'A')],
        ),
      ),
      commandContext: EditorCommandContext(
        configuration: EditorConfiguration(inlineFormats: {}, lineHeight: false),
        localOnly: true,
      ),
    );
    final state = controller.editorState;
    state.selection = Selection.single(path: [0], startOffset: 0, endOffset: 1);
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [AppFlowyEditorLocalizations.delegate],
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => showEditorSelectionFormats(context, state),
                child: const Text('Formats'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Formats'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-inline-letter-spacing')), findsNothing);
      expect(find.byKey(const ValueKey('editor-block-line-height')), findsNothing);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(controller.close);
    }
  });

  test('spacing preserves heading list quote and other attributes', () async {
    final controller = DocumentEditorController(
      document: Document(
        root: Node(
          type: 'page',
          children: [
            for (final type in [
              HeadingBlockKeys.type,
              QuoteBlockKeys.type,
              BulletedListBlockKeys.type,
              NumberedListBlockKeys.type,
              TodoListBlockKeys.type,
            ])
              Node(
                type: type,
                attributes: {
                  blockComponentDelta: (Delta()..insert('A', attributes: {AppFlowyRichTextKeys.bold: true})).toJson(),
                  if (type == HeadingBlockKeys.type) HeadingBlockKeys.level: 2,
                  if (type == TodoListBlockKeys.type) TodoListBlockKeys.checked: true,
                },
              ),
          ],
        ),
      ),
    );
    final state = controller.editorState;
    try {
      state.selection = Selection(
        start: Position(path: [0]),
        end: Position(path: [4], offset: 1),
      );
      await setCollabParagraphLineHeight(state, 2.5);
      await formatCollabParagraphSelection(state, state.selection!, {'t:ls': .1});
      for (final node in state.document.root.children) {
        final style = collabParagraphTextStyle(node, const TextStyle(fontSize: 16), node.delta!.first.attributes!);
        expect(style.height, 2.5);
        expect(style.letterSpacing, closeTo((node.type == HeadingBlockKeys.type ? 28.8 : 16) * .1, .001));
        expect(node.delta!.first.attributes![AppFlowyRichTextKeys.bold], isTrue);
      }
      expect(state.document.first!.attributes[HeadingBlockKeys.level], 2);
      expect(state.document.root.children.last.attributes[TodoListBlockKeys.checked], isTrue);
    } finally {
      await controller.close();
    }
  });

  test('line height skips void/code and exclusive next paragraph endpoint', () async {
    final controller = DocumentEditorController(
      document: Document(
        root: Node(
          type: 'page',
          children: [
            paragraphNode(text: 'A'),
            Node(type: 'divider'),
            Node(type: 'code', attributes: {blockComponentDelta: (Delta()..insert('code')).toJson()}),
            paragraphNode(text: 'B'),
          ],
        ),
      ),
    );
    final state = controller.editorState;
    try {
      state.selection = Selection(
        start: Position(path: [0]),
        end: Position(path: [3]),
      );
      expect(await setCollabParagraphLineHeight(state, 1.75), isTrue);
      expect(readCollabParagraph(state.document.first!).values['lh'], 1.75);
      for (final node in state.document.root.children.skip(1)) {
        expect(node.attributes[paragraphPropertyAttribute('lh')], isNull);
      }
      expect(await setCollabParagraphLineHeight(state, double.nan), isFalse);
      expect(await setCollabParagraphLineHeight(state, .5), isFalse);
      state.undoManager.undo();
      expect(readCollabParagraph(state.document.first!).values['lh'], isNull);
    } finally {
      await controller.close();
    }
  });
}
