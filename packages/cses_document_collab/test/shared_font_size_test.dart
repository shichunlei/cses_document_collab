import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_text_style.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 借用[document]构建公共编辑视图；会话由测试在视图卸载后关闭。
Widget _app(DocumentEditorController document) => MaterialApp(
  localizationsDelegates: const [AppFlowyEditorLocalizations.delegate],
  home: Scaffold(body: DocumentEditorView(editorState: document.editorState)),
);

/// 使用[tester]从公共Aa菜单进入横向字号子菜单，已打开时保持原状态。
Future<void> _openFontSize(WidgetTester tester) async {
  if (find.byKey(const ValueKey('editor-font-size-menu')).evaluate().isNotEmpty) return;
  if (find.byKey(const ValueKey('editor-inline-style-menu')).evaluate().isEmpty) {
    await tester.tap(find.byKey(const ValueKey('editor-shortcut-inline-style')));
    await tester.pumpAndSettle();
  }
  await tester.drag(find.byKey(const ValueKey('editor-inline-style-menu')), const Offset(-300, 0));
  await tester.pumpAndSettle();
  final button = find.byKey(const ValueKey('editor-inline-font-size'));
  expect(button, findsOneWidget);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

/// 验证两种默认预设通过相同字号入口写入、撤销和重做，并拒绝撤权后的旧面板。
void main() {
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('keyboardHeightEventChannel'),
      MockStreamHandler.inline(onListen: (_, events) => events.success(0.0)),
    );
  });
  for (final local in [true, false]) {
    testWidgets('default font size menu applies and preserves history local=$local', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final document = DocumentEditorController(
        document: Document(
          root: Node(
            type: 'page',
            children: [paragraphNode(text: 'Alpha')],
          ),
        ),
        commandContext: EditorCommandContext(
          configuration: local ? EditorConfiguration.local : EditorConfiguration.document,
          localOnly: local,
        ),
      );
      final state = document.editorState;
      try {
        await tester.pumpWidget(_app(document));
        await tester.pumpAndSettle();
        state.selection = Selection.single(path: [0], startOffset: 0, endOffset: 5);
        await tester.pumpAndSettle();
        await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
        await _openFontSize(tester);
        expect(find.byType(BottomSheet), findsNothing);
        expect(tester.testTextInput.isVisible, isTrue);
        expect(
          tester.widget<SingleChildScrollView>(find.byKey(const ValueKey('editor-font-size-menu'))).scrollDirection,
          Axis.horizontal,
        );
        for (final size in [12, 16, 20, 24, 28, 32, 36]) {
          expect(find.byKey(ValueKey('editor-font-size-$size')), findsOneWidget);
        }
        await tester.tap(find.byKey(const ValueKey('editor-font-size-24')));
        await tester.pumpAndSettle();
        expect(state.document.first!.delta!.first.attributes?['t:px'], 24);
        expect(state.document.first!.delta!.toPlainText(), 'Alpha');
        expect(find.byKey(const ValueKey('editor-font-size-menu')), findsOneWidget);
        expect(tester.widget<Semantics>(find.byKey(const ValueKey('editor-font-size-24'))).properties.selected, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        state.undoManager.undo();
        await tester.pumpAndSettle();
        expect(state.document.first!.delta!.first.attributes?['t:px'], isNull);
        state.undoManager.redo();
        await tester.pumpAndSettle();
        expect(state.document.first!.delta!.first.attributes?['t:px'], 24);

        await tester.ensureVisible(find.byKey(const ValueKey('editor-font-size-28')));
        await tester.tap(find.byKey(const ValueKey('editor-font-size-28')));
        await tester.pumpAndSettle();
        expect(state.document.first!.delta!.first.attributes?['t:px'], 28);
        state.undoManager.undo();
        await tester.pumpAndSettle();
        expect(state.document.first!.delta!.first.attributes?['t:px'], 24);
        state.undoManager.redo();
        await tester.pumpAndSettle();
        expect(state.document.first!.delta!.first.attributes?['t:px'], 28);
        expect(tester.widget<Semantics>(find.byKey(const ValueKey('editor-font-size-28'))).properties.selected, isTrue);
        state.selection = Selection.single(path: [0], startOffset: 0, endOffset: 5);
        await tester.pumpAndSettle();
        await _openFontSize(tester);
        state.editable = false;
        state.editable = true;
        await tester.ensureVisible(find.byKey(const ValueKey('editor-font-size-36')));
        await tester.tap(find.byKey(const ValueKey('editor-font-size-36')));
        await tester.pumpAndSettle();
        expect(state.document.first!.delta!.first.attributes?['t:px'], 28);
        await tester.tap(find.byKey(const ValueKey('editor-font-size-back')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('editor-inline-style-menu')), findsOneWidget);
        await _openFontSize(tester);
        await tester.ensureVisible(find.byKey(const ValueKey('editor-font-size-36')));
        await tester.tap(find.byKey(const ValueKey('editor-font-size-36')));
        await tester.pumpAndSettle();
        expect(state.document.first!.delta!.first.attributes?['t:px'], 36);
        final reset = find.byKey(const ValueKey('editor-font-size-default'));
        await tester.ensureVisible(reset);
        await tester.tap(reset);
        await tester.pumpAndSettle();
        expect(state.document.first!.delta!.first.attributes?['t:px'], isNull);
        expect(tester.widget<Semantics>(reset).properties.selected, isTrue);
        state.undoManager.undo();
        await tester.pumpAndSettle();
        expect(state.document.first!.delta!.first.attributes?['t:px'], 36);
        expect(tester.widget<Semantics>(reset).properties.selected, isFalse);
        expect(tester.widget<Semantics>(find.byKey(const ValueKey('editor-font-size-36'))).properties.selected, isTrue);
        state.undoManager.redo();
        await tester.pumpAndSettle();
        expect(state.document.first!.delta!.first.attributes?['t:px'], isNull);
        expect(tester.widget<Semantics>(reset).properties.selected, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(document.close);
      }
    });
  }

  testWidgets('font choices scroll at narrow large text and follow the current caret', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final document = LocalEditorController(
      initialText: 'AB',
      configuration: EditorConfiguration(
        blocks: [EditorBlock.paragraph],
        inlineFormats: [EditorInlineFormat.fontSize],
        fontSizes: [12, 24, 4096],
      ),
    );
    final state = document.editorState;
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
      await tester.pumpAndSettle();
      state.selection = Selection.collapsed(Position(path: [0]));
      await tester.pumpAndSettle();
      await _openFontSize(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('editor-font-size-4096')));
      expect(tester.getSize(find.text('4096')).width, greaterThan(48));
      expect(find.byKey(const ValueKey('editor-font-size-default')).hitTestable(), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('editor-font-size-24')));
      await tester.tap(find.byKey(const ValueKey('editor-font-size-24')));
      await tester.pumpAndSettle();
      expect(state.toggledStyle['t:px'], 24);
      await state.apply(state.transaction..insertText(state.document.first!, 0, 'Z', attributes: state.toggledStyle));
      await tester.pumpAndSettle();
      expect(state.document.first!.delta!.first.attributes?['t:px'], 24);
      state.selection = Selection.collapsed(Position(path: [0], offset: 1));
      await tester.pumpAndSettle();
      final reset = find.byKey(const ValueKey('editor-font-size-default'));
      await tester.ensureVisible(reset);
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(state.toggledStyle['t:px'], isNull);
      expect(state.document.first!.delta!.first.attributes?['t:px'], 24);
      await state.apply(state.transaction..insertText(state.document.first!, 1, 'X', attributes: state.toggledStyle));
      await tester.pumpAndSettle();
      expect(state.document.first!.delta!.slice(1, 2).first.attributes?['t:px'], isNull);
      state.selection = Selection.single(path: [0], startOffset: 0, endOffset: 4);
      await tester.pumpAndSettle();
      expect(tester.widget<Semantics>(find.byKey(const ValueKey('editor-font-size-24'))).properties.selected, isFalse);
      expect(tester.widget<Semantics>(reset).properties.selected, isFalse);
      await tester.ensureVisible(find.byKey(const ValueKey('editor-font-size-24')));
      await tester.tap(find.byKey(const ValueKey('editor-font-size-24')));
      await tester.pumpAndSettle();
      expect(state.document.first!.delta!.everyAttributes((attributes) => attributes['t:px'] == 24), isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(document.close);
    }
  });

  for (final local in [true, false]) {
    testWidgets('default size clears legacy overrides and inherits heading local=$local', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final node = Node(
        type: HeadingBlockKeys.type,
        attributes: {
          HeadingBlockKeys.level: 2,
          blockComponentDelta:
              (Delta()..insert(
                    'Title',
                    attributes: {
                      's:fontSize': '30px',
                      AppFlowyRichTextKeys.bold: true,
                      AppFlowyRichTextKeys.textColor: '0xff123456',
                    },
                  ))
                  .toJson(),
        },
      );
      final document = DocumentEditorController(
        document: Document(
          root: Node(type: 'page', children: [node]),
        ),
        commandContext: EditorCommandContext(
          configuration: local ? EditorConfiguration.local : EditorConfiguration.document,
          localOnly: local,
        ),
      );
      final state = document.editorState;
      try {
        await tester.pumpWidget(_app(document));
        await tester.pumpAndSettle();
        state.selection = Selection.single(path: [0], startOffset: 0, endOffset: 5);
        await tester.pumpAndSettle();
        await _openFontSize(tester);
        final reset = find.byKey(const ValueKey('editor-font-size-default'));
        expect(tester.widget<Semantics>(reset).properties.selected, isFalse);
        await tester.tap(find.byKey(const ValueKey('editor-font-size-24')));
        await tester.pumpAndSettle();
        expect(state.document.first!.delta!.first.attributes?['t:px'], 24);
        await tester.ensureVisible(reset);
        await tester.tap(reset);
        await tester.pumpAndSettle();
        final current = state.document.first!;
        final attributes = current.delta!.first.attributes!;
        expect(attributes['t:px'], isNull);
        expect(attributes['s:fontSize'], isNull);
        expect(attributes[AppFlowyRichTextKeys.bold], isTrue);
        expect(attributes[AppFlowyRichTextKeys.textColor], '0xff123456');
        expect(current.type, HeadingBlockKeys.type);
        expect(current.attributes[HeadingBlockKeys.level], 2);
        expect(
          collabParagraphTextStyle(current, const TextStyle(fontSize: 16), attributes).fontSize,
          closeTo(28.8, .001),
        );
        final defaults = paragraphDefaultsToAttributes(readCollabParagraph(current).values['textDefaults']);
        expect(defaults['t:px'], isNull);
        expect(defaults['s:fontSize'], isNull);
        expect(tester.widget<Semantics>(reset).properties.selected, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(document.close);
      }
    });
  }

  testWidgets('selection format sheet hosts the same font row without another sheet', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final document = DocumentEditorController(
      document: Document(
        root: Node(
          type: 'page',
          children: [paragraphNode(text: 'Alpha')],
        ),
      ),
    );
    final state = document.editorState;
    state.selection = Selection.single(path: [0], startOffset: 0, endOffset: 5);
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
      await tester.ensureVisible(find.byKey(const ValueKey('editor-inline-font-size')));
      await tester.tap(find.byKey(const ValueKey('editor-inline-font-size')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byKey(const ValueKey('editor-font-size-menu')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('editor-font-size-24')));
      await tester.tap(find.byKey(const ValueKey('editor-font-size-24')));
      await tester.pumpAndSettle();
      expect(state.document.first!.delta!.first.attributes?['t:px'], 24);
      await tester.tap(find.byKey(const ValueKey('editor-font-size-back')));
      await tester.pumpAndSettle();
      expect(find.text('文字样式'), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(document.close);
    }
  });
}
