import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:cses_mobile_collab_demo/src/collab/collab_controller.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_block_delete.dart';
import 'package:cses_mobile_collab_demo/src/ui/collaborative_editor_page.dart';
import 'package:cses_mobile_collab_demo/src/ui/editor_shortcut_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(0.0),
          ),
        );
  });

  testWidgets('standalone page owns the full-screen editor UI', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final collab = CollabController();
    addTearDown(collab.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          AppFlowyEditorLocalizations.delegate,
        ],
        home: CollaborativeEditorPage(collab: collab),
      ),
    );

    expect(
      find.byKey(const ValueKey('collaborative-editor-page')),
      findsOneWidget,
    );
    expect(find.byType(AppFlowyEditor), findsOneWidget);
    final editor = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));
    expect(editor.shrinkWrap, isFalse);
    expect(editor.blockComponentBuilders, contains(csesCodeBlockType));
    // Link and video are custom components; image remains available through
    // AppFlowy's standard builder map. All three must render in both modes.
    expect(editor.blockComponentBuilders, contains(csesLinkBlockType));
    expect(editor.blockComponentBuilders, contains(csesVideoBlockType));
    expect(editor.blockComponentBuilders, contains(ImageBlockKeys.type));
    expect(editor.blockComponentBuilders, contains(csesDocumentCoverBlockType));
    expect(editor.blockComponentBuilders, contains(csesDocumentTitleBlockType));
    final titleBuilder =
        editor.blockComponentBuilders[csesDocumentTitleBlockType]!
            as ParagraphBlockComponentBuilder;
    expect(
      titleBuilder.configuration
          .textStyle(Node(type: csesDocumentTitleBlockType))
          .fontSize,
      38,
    );
    expect(
      editor.commandShortcutEvents.first,
      same(collabUrlBackedBlockBackspaceCommand),
    );
    expect(
      find.byKey(const ValueKey('collaborative-appflowy-editor')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('editor-undo')), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-redo')), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-mode-toggle')), findsOneWidget);
    expect(find.text('预览'), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-connection-bar')), findsOneWidget);
    expect(collab.editorState.editable, isTrue);
    expect(tester.takeException(), isNull);

    collab.editorState.selection = Selection.single(path: [0], startOffset: 0);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('editor-mode-toggle')));
    await tester.pumpAndSettle();

    expect(collab.editorState.editable, isFalse);
    expect(collab.editorState.selection, isNull);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-undo')), findsNothing);
    expect(find.byKey(const ValueKey('editor-redo')), findsNothing);
    expect(find.byType(EditorShortcutToolbar), findsNothing);
    expect(find.byType(AppFlowyEditor), findsOneWidget);
    expect(
      tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editable,
      isFalse,
    );
    expect(
      tester
          .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
          .disableKeyboardService,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('editor-mode-toggle')));
    await tester.pumpAndSettle();

    expect(collab.editorState.editable, isTrue);
    expect(find.text('预览'), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-undo')), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-redo')), findsOneWidget);
    expect(find.byType(EditorShortcutToolbar), findsOneWidget);
    expect(
      tester
          .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
          .disableKeyboardService,
      isFalse,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
