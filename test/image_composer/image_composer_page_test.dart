import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/image_composer/show_image_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 宿主功能入口的编辑、无编辑装饰预览、返回编辑及退出释放回归。
void main() {
  testWidgets('preview uses an isolated noninteractive document and has no export', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var completed = false;
    Future<void>? routeTask;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                routeTask = showImageComposer(
                  context: context,
                  initialText: '本地标题\n正文',
                  editorConfig: EditorConfiguration(
                    blocks: [EditorBlock.paragraph, EditorBlock.heading],
                    headingLevels: {1, 3},
                  ),
                );
                await routeTask;
                completed = true;
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final source = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;
    source.selection = Selection.single(path: [0], startOffset: 0, endOffset: 4);
    await tester.pumpAndSettle();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.tap(find.byKey(const ValueKey('image-composer-preview-toggle')));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    final preview = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));
    expect(identical(preview.editorState, source), isFalse);
    expect(preview.editorState.selection, isNull);
    expect(preview.editable, isFalse);
    expect(preview.disableSelectionService, isTrue);
    expect(preview.disableKeyboardService, isTrue);
    expect(tester.widget<DocumentEditorView>(find.byType(DocumentEditorView)).preview, isTrue);
    expect(find.byKey(const ValueKey('editor-mobile-toolbar')), findsNothing);
    expect(find.byKey(const ValueKey('editor-selection-menu')), findsNothing);
    expect(find.byKey(const ValueKey('image-composer-generate')), findsNothing);
    expect(find.byTooltip('锁定'), findsNothing);
    expect(find.byTooltip('更多'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('image-composer-template-sunset')));
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const ValueKey('image-composer-preview')));
    await tester.pumpAndSettle();
    expect(preview.editorState.selection, isNull);
    expect(find.byKey(const ValueKey('editor-selection-menu')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('image-composer-preview-toggle')));
    await tester.pumpAndSettle();
    expect(preview.editorState.isDisposed, isTrue);
    expect(tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState, same(source));
    expect(source.document.root.children.first.delta!.toPlainText(), '本地标题');
    expect(source.editable, isTrue);
    await tester.tap(find.byKey(const ValueKey('image-composer-back')));
    await tester.pumpAndSettle();
    expect(source.isDisposed, isTrue);
    await tester.runAsync(() async {
      await routeTask;
    });
    await tester.pump();
    expect(completed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty narrow preview does not display an input placeholder', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showImageComposer(context: context),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('image-composer-preview-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('输入文字…'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('image-composer-back')));
    await tester.pumpAndSettle();
  });
  testWidgets('long preview scrolls while todo controls remain inert', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showImageComposer(context: context, initialText: List.generate(60, (index) => '第$index段').join('\n')),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final source = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;
    source.selection = Selection.collapsed(Position(path: [0]));
    final conversion = source.formatNode(
      source.selection!,
      (node) => Node(type: 'todo_list', attributes: {...node.attributes, TodoListBlockKeys.checked: false}),
    );
    await tester.pumpAndSettle();
    await conversion;
    await tester.tap(find.byKey(const ValueKey('image-composer-preview-toggle')));
    await tester.pumpAndSettle();
    final editor = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));
    final scroll = editor.editorScrollController!;
    final before = scroll.offsetNotifier.value;
    await tester.tapAt(tester.getTopLeft(find.byKey(const ValueKey('image-composer-preview'))) + const Offset(52, 56));
    await tester.pumpAndSettle();
    expect(editor.editorState.document.root.children.first.attributes[TodoListBlockKeys.checked], isFalse);
    await tester.drag(find.byKey(const ValueKey('image-composer-preview')), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(scroll.offsetNotifier.value, greaterThan(before));
    expect(editor.editorState.selection, isNull);
    await tester.tap(find.byKey(const ValueKey('image-composer-back')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
