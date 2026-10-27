import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_page.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/file_journal_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 在隔离目录用生产日记页验证平台输入、文件自动保存、预览和路由重开，不访问业务服务。
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('offline journal edits, previews and restores on Android', (
    tester,
  ) async {
    final support = await getApplicationSupportDirectory();
    final base = await Directory(
      p.join(support.path, 'journal-device-validation'),
    ).create(recursive: true);
    final directory = await base.createTemp('run-');
    final store = FileJournalStore(
      directory: directory,
      scope: 'device-journal',
    );
    await store.write(JournalDraft.blank(DateTime(2026, 10, 22)));
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => LocalJournalPage(store: store),
                    ),
                  ),
                  child: const Text('打开设备日记'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开设备日记'));
      await tester.pumpAndSettle();
      final editor = tester
          .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
          .editorState;
      editor.selection = Selection.collapsed(Position(path: [0, 0]));
      await tester.pumpAndSettle();
      // 通过平台文字输入链提交中文候选，而非直接修改文档数据。
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '今天完成了重要目标，记录自己的成长。',
          selection: TextSelection.collapsed(offset: 18),
          composing: TextRange(start: 0, end: 18),
        ),
      );
      await tester.pumpAndSettle();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '今天完成了重要目标，记录自己的成长。',
          selection: TextSelection.collapsed(offset: 18),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        editor.getNodeAtPath([0, 0])!.delta!.toPlainText(),
        '今天完成了重要目标，记录自己的成长。',
      );
      await tester.tap(find.byKey(const ValueKey('guidance-add-reflection')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('guidance-add-self-check')));
      await tester.pumpAndSettle();
      for (var i = 1; i < 3; i++) {
        await editor.apply(
          editor.transaction..insertText(
            editor.getNodeAtPath([i, 0])!,
            0,
            i == 1 ? '耐心把一件小事做好。' : '目标已完成，明天继续改进。',
          ),
        );
      }
      editor.selection = null;
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      final saved = await store.read();
      expect(saved!.documentJson, contains('记录自己的成长'));
      final before = jsonEncode(editor.document.toJson());
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
      await File(
        p.join(base.path, 'editor.png'),
      ).writeAsBytes(await binding.takeScreenshot('journal-editor'));
      await tester.tap(find.byKey(const ValueKey('journal-preview')));
      await tester.pumpAndSettle();
      final preview = tester
          .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
          .editorState;
      expect(preview.editable, isFalse);
      expect(jsonEncode(preview.document.toJson()), before);
      await File(
        p.join(base.path, 'preview.png'),
      ).writeAsBytes(await binding.takeScreenshot('journal-preview'));
      await tester.drag(find.byType(AppFlowyEditor), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(find.text('自检'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('journal-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开设备日记'));
      await tester.pumpAndSettle();
      final restored = tester
          .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
          .editorState;
      expect(jsonEncode(restored.document.toJson()), before);
      expect((await store.read())!.date, '2026-10-22');
      await tester.tap(find.byKey(const ValueKey('journal-back')));
      await tester.pumpAndSettle();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await directory.delete(recursive: true);
    }
  });
}
