import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:cses_mobile_collab_demo/src/collab/collab_controller.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_block_delete.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_list_editing.dart';
import 'package:cses_mobile_collab_demo/src/ui/collaborative_editor_page.dart';
import 'package:cses_mobile_collab_demo/src/ui/editor_shortcut_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证页面只拥有展示模式，始终遵守宿主的文档编辑能力。
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

  for (final blockType in [
    ParagraphBlockKeys.type,
    NumberedListBlockKeys.type,
    BulletedListBlockKeys.type,
    TodoListBlockKeys.type,
  ]) {
    testWidgets('$blockType rows stay compact in edit and preview', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          for (var i = 0; i < 6; i++)
            CollabEditorBlock(id: 'row-$i', blockType: blockType, text: '$i'),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final collab = _ReadyCollabController(
        testEditorState: adapter.editorState,
      );
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
      await tester.pumpAndSettle();

      void expectCompactRows() {
        final nodes = adapter.editorState.document.root.children;
        for (var i = 1; i < nodes.length; i++) {
          final previous = tester.getTopLeft(find.byKey(nodes[i - 1].key));
          final current = tester.getTopLeft(find.byKey(nodes[i].key));
          // Measure rendered positions: page padding must not repeat per row.
          expect(current.dy - previous.dy, inInclusiveRange(20, 32));
        }
        expect(tester.takeException(), isNull);
      }

      expectCompactRows();
      await tester.tap(find.byKey(const ValueKey('editor-mode-toggle')));
      await tester.pumpAndSettle();
      expectCompactRows();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('standalone page owns the full-screen editor UI', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final collab = _ReadyCollabController();
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
    expect(editor.characterShortcutEvents.first, same(collabListEnter));
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
      same(collabBlockBackspaceCommand),
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

  testWidgets(
    'remote read-only capability disables all editing and preserves preview choice',
    (tester) async {
      final collab = _ReadyCollabController();
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
      collab.setReadOnlyReason('包含未知块');
      await tester.pumpAndSettle();
      expect(collab.editorState.editable, isFalse);
      expect(find.text('只读：包含未知块'), findsOneWidget);
      expect(find.byType(EditorShortcutToolbar), findsNothing);
      expect(find.byKey(const ValueKey('editor-undo')), findsNothing);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('editor-mode-toggle')),
            )
            .onPressed,
        isNull,
      );
      collab.setReadOnlyReason(null);
      await tester.pumpAndSettle();
      expect(collab.editorState.editable, isTrue);
      await tester.tap(find.byKey(const ValueKey('editor-mode-toggle')));
      await tester.pumpAndSettle();
      collab.setReadOnlyReason('包含锁定块');
      collab.setReadOnlyReason(null);
      await tester.pumpAndSettle();
      expect(collab.editorState.editable, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(collab.hasPageListeners, isFalse);
    },
  );
}

/// 不加载原生库的页面宿主 Fake；只模拟已初始化文档的能力变化。
class _ReadyCollabController extends CollabController {
  _ReadyCollabController({this.testEditorState});

  final EditorState? testEditorState;

  @override
  EditorState get editorState => testEditorState ?? super.editorState;

  String? _reason;

  /// 页面卸载后不应再持有模式监听，测试通过子类访问受保护状态。
  bool get hasPageListeners => hasListeners;

  /// 页面测试的离线文档已加载。
  @override
  bool get initialized => true;

  /// 模拟 Rust 返回的只读原因，null 表示结构可编辑。
  @override
  String? get readOnlyReason => _reason;

  /// 文档能力由测试持有，不访问全局 Rust 引擎。
  @override
  bool get canEdit => _reason == null;

  /// 发布 [reason] 的能力变化；null 恢复编辑，已有预览选择由页面保留。
  void setReadOnlyReason(String? reason) {
    _reason = reason;
    notifyListeners();
  }
}
