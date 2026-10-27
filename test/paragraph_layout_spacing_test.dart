import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/core/document_editor_controller.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 在真实格式面板中检查段落与引用的布局按钮间距，保持正文和菜单行为。
void main() {
  for (final type in [ParagraphBlockKeys.type, QuoteBlockKeys.type]) {
    for (final width in [320.0, 390.0]) {
      testWidgets('layout trailing controls keep spacing type=$type width=$width', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final controller = DocumentEditorController(
          document: Document(
            root: Node(
              type: 'page',
              children: [
                Node(type: type, attributes: {blockComponentDelta: (Delta()..insert('Alpha')).toJson()}),
              ],
            ),
          ),
        );
        final state = controller.editorState;
        state.selection = Selection.single(path: [0], startOffset: 0, endOffset: 5);
        final before = state.document.toJson();
        try {
          await tester.pumpWidget(
            MaterialApp(
              localizationsDelegates: const [AppFlowyEditorLocalizations.delegate],
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(width == 320 ? 2 : 1)),
                child: child!,
              ),
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
          final menu = find.byKey(const ValueKey('editor-block-layout-menu'));
          await tester.ensureVisible(menu);
          await tester.drag(menu, const Offset(-1000, 0));
          await tester.pumpAndSettle();
          final keys = [
            'editor-block-background-color',
            if (type == QuoteBlockKeys.type) 'editor-block-border-color',
            'editor-next-paragraph-default',
            'editor-next-paragraph-same',
            'editor-next-paragraph-body',
          ];
          for (var index = 1; index < keys.length; index++) {
            final previous = tester.getRect(find.byKey(ValueKey(keys[index - 1])));
            final current = tester.getRect(find.byKey(ValueKey(keys[index])));
            expect(current.left - previous.right, closeTo(5, .01), reason: '${keys[index - 1]} → ${keys[index]}');
          }
          expect(state.document.toJson(), before);
          await tester.tap(find.text('完成'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(controller.close);
        }
      });
    }
  }
}
