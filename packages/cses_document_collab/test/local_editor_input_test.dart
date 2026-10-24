import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/local_editor_controller.dart';
import 'package:cses_document_collab/src/editor/document_editor_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 使用真实AppFlowy输入连接验证中文输入、回车及关闭，不初始化Rust。
void main() {
  testWidgets(
    'local mobile input connection accepts Chinese, styles and newline',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('keyboardHeightEventChannel'),
            (_) async => null,
          );
      final local = LocalEditorController();
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
              body: DocumentEditorView(
                editorState: local.editorState,
                padding: const EdgeInsets.all(24),
              ),
            ),
          ),
        );
        await tester.pump();
        final selected = local.editorState.updateSelectionWithReason(
          Selection.collapsed(Position(path: [0])),
          reason: SelectionUpdateReason.uiEvent,
        );
        await tester.pump();
        await selected;
        await tester.pump(const Duration(milliseconds: 150));
        expect(tester.testTextInput.hasAnyClients, isTrue);
        final formatting = local.format({
          't:px': 24,
          AppFlowyRichTextKeys.bold: true,
        });
        await tester.pump(const Duration(milliseconds: 200));
        await formatting;
        await _type(tester, '中文输入');
        expect(
          local.editorState.document.root.children.single.delta!.toPlainText(),
          '中文输入',
        );
        await _type(tester, '\n');
        expect(local.editorState.document.root.children.length, 2);
        await _type(tester, '第二段');
        expect(
          local.editorState.document.root.children.last.delta!.toPlainText(),
          '第二段',
        );
        expect(tester.takeException(), isNull);
      } finally {
        local.editorState.selection = null;
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        // 在自动测试结束的输入桩清理前完成客户端注销，避免框架末帧等待旧连接。
        tester.testTextInput.unregister();
        await tester.pump();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('keyboardHeightEventChannel'),
              null,
            );
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );
}

/// 在借用 [tester] 的当前输入连接插入 [text]，等待IME生成的编辑事务。
Future<void> _type(WidgetTester tester, String text) async {
  final value = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
  final offset = value.selection.extentOffset;
  tester.testTextInput.updateEditingValue(
    value.copyWith(
      text: value.text.replaceRange(offset, offset, text),
      selection: TextSelection.collapsed(offset: offset + text.length),
      composing: TextRange.empty,
    ),
  );
  await tester.pump(const Duration(milliseconds: 200));
}
