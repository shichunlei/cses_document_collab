import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 在原工具栏上验证本地功能范围、格式事务和宿主隔离。
void main() {
  testWidgets('image editor uses original menus and isolates host services', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockStreamHandler(
      const EventChannel('keyboardHeightEventChannel'),
      MockStreamHandler.inline(onListen: (_, events) => events.success(0.0)),
    );
    addTearDown(
      () => messenger.setMockStreamHandler(
        const EventChannel('keyboardHeightEventChannel'),
        null,
      ),
    );
    final owner = Object();
    var hostRequests = 0;
    CollabRuntime.acquire(
      owner,
      CollabHostServices(
        pickMentionUser: (_, {required keyword, required canEdit}) async {
          hostRequests++;
          return null;
        },
        onError: (_, _, _, _) => hostRequests++,
      ),
    );
    addTearDown(() => CollabRuntime.release(owner));
    final local = LocalEditorController(
      initialText: 'Text',
      configuration: EditorConfiguration.text,
    );
    addTearDown(local.close);
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            AppFlowyEditorLocalizations.delegate,
          ],
          home: Scaffold(
            body: DocumentEditorView(editorState: local.editorState),
          ),
        ),
      );
      local.editorState.selection = Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 4,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('editor-mobile-toolbar')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('editor-shortcut-image')), findsNothing);
      expect(
        find.byKey(const ValueKey('editor-shortcut-mention')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('editor-shortcut-inline-style')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('editor-inline-superscript')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('editor-inline-bold')));
      await tester.pumpAndSettle();
      expect(
        local
            .editorState
            .document
            .root
            .children
            .single
            .delta!
            .first
            .attributes?[AppFlowyRichTextKeys.bold],
        isTrue,
      );
      final fontSize = find.byKey(const ValueKey('editor-inline-font-size'));
      await tester.drag(
        find.byKey(const ValueKey('editor-inline-style-menu')),
        const Offset(-300, 0),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(fontSize);
      await tester.tap(fontSize);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-font-size-24')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(
        local
            .editorState
            .document
            .root
            .children
            .single
            .delta!
            .first
            .attributes?['t:px'],
        24,
      );
      await tester.tap(find.byKey(const ValueKey('editor-font-size-back')));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('editor-inline-style-menu')),
        const Offset(-300, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-inline-font-size')));
      await tester.pumpAndSettle();
      local.editorState.editable = false;
      local.editorState.editable = true;
      await tester.ensureVisible(
        find.byKey(const ValueKey('editor-font-size-36')),
      );
      await tester.tap(find.byKey(const ValueKey('editor-font-size-36')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(
        local
            .editorState
            .document
            .root
            .children
            .single
            .delta!
            .first
            .attributes?['t:px'],
        24,
      );
      local.editorState.selection = Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 4,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('editor-shortcut-block-layout')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-block-indent')), findsNothing);
      expect(
        find.byKey(const ValueKey('editor-block-align-distributed')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('editor-block-background-color')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('editor-shortcut-add')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('editor-add-block-sheet')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('editor-shortcut-code-block')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('editor-shortcut-image-block')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('editor-shortcut-table')), findsNothing);
      expect(
        find.byKey(const ValueKey('editor-shortcut-heading-4')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('editor-shortcut-heading-5')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('editor-add-block-close')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(hostRequests, 0);
      expect(CollabRuntime.owns(owner), isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      local.editorState.selection = null;
      await tester.pumpWidget(const SizedBox.shrink());
      tester.testTextInput.unregister();
      await tester.pump(const Duration(milliseconds: 500));
    }
  });
  testWidgets('instance configuration filters original menus and shortcuts', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final local = LocalEditorController(
      initialText: 'Text',
      configuration: EditorConfiguration(
        blocks: [EditorBlock.paragraph, EditorBlock.heading],
        headingLevels: {1, 3},
        inlineFormats: {EditorInlineFormat.bold, EditorInlineFormat.fontSize},
        fontSizes: [18, 30],
        alignments: {'center'},
        nextParagraphStyle: false,
      ),
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            AppFlowyEditorLocalizations.delegate,
          ],
          home: Scaffold(
            body: DocumentEditorView(editorState: local.editorState),
          ),
        ),
      );
      local.editorState.selection = Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 4,
      );
      await tester.pumpAndSettle();
      final editor = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));
      expect(
        editor.commandShortcutEvents.any(
          (event) => event.key == 'toggle italic',
        ),
        isFalse,
      );
      expect(
        editor.characterShortcutEvents.contains(formatAsteriskToBulletedList),
        isFalse,
      );
      await tester.tap(
        find.byKey(const ValueKey('editor-shortcut-inline-style')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-inline-bold')), findsOneWidget);
      expect(find.byKey(const ValueKey('editor-inline-italic')), findsNothing);
      expect(
        find.byKey(const ValueKey('editor-inline-text-color')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('editor-inline-font-size')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-font-size-18')), findsOneWidget);
      expect(find.byKey(const ValueKey('editor-font-size-30')), findsOneWidget);
      expect(find.byKey(const ValueKey('editor-font-size-24')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('editor-font-size-18')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(
        local
            .editorState
            .document
            .root
            .children
            .single
            .delta!
            .first
            .attributes?['t:px'],
        18,
      );
      await tester.tap(
        find.byKey(const ValueKey('editor-shortcut-block-layout')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('editor-block-align-center')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('editor-block-align-left')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('editor-next-paragraph-default')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('editor-shortcut-add')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('editor-shortcut-heading-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('editor-shortcut-heading-3')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('editor-shortcut-heading-2')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('editor-shortcut-quote')), findsNothing);
      expect(
        find.byKey(const ValueKey('editor-shortcut-todo-list')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('editor-add-block-close')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    } finally {
      local.editorState.selection = null;
      await tester.pumpWidget(const SizedBox.shrink());
      tester.testTextInput.unregister();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.runAsync(local.close);
    }
  });
}
