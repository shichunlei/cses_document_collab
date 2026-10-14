import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:example/meeting/meeting_document_adapter.dart';
import 'package:example/pages/meeting_description_demo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercises the example page with the bundled meeting description asset.
void main() {
  testWidgets('meeting sample opens in the editor with export controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          AppFlowyEditorLocalizations.delegate,
        ],
        supportedLocales: [Locale('en'), Locale('zh')],
        home: MeetingDescriptionDemo(),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('会议描述 · AppFlowy Demo'), findsOneWidget);
    expect(find.text('复制服务端 JSON'), findsOneWidget);
    final editor = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));
    expect(
      editor.editorState.document.root.children.first.delta?.toPlainText(),
      '会议描述',
    );
    await tester.scrollUntilVisible(
      find.text('C20220000006547stp.pdf'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('C20220000006547stp.pdf'), findsOneWidget);

    final attachmentTile = find.ancestor(
      of: find.text('C20220000006547stp.pdf'),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: attachmentTile, matching: find.byTooltip('编辑属性')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '修改后的附件.pdf');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final exported = const MeetingDocumentAdapter().export(
      editor.editorState.document,
    );
    final attachments = (exported['children'] as List).cast<Map>();
    expect(
      (attachments.firstWhere(
            (node) => (node['props'] as Map?)?['name'] == '修改后的附件.pdf',
          )['props']
          as Map)['url'],
      contains('.pdf'),
    );

    await tester.tap(find.text('添加块'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('分割线').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('分割线').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '新增分割线');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final withDivider = const MeetingDocumentAdapter().export(
      editor.editorState.document,
    );
    expect(
      (withDivider['children'] as List).cast<Map>().any(
        (node) =>
            node['flavour'] == 'divider' &&
            (node['props'] as Map?)?['text'] == '新增分割线',
      ),
      isTrue,
    );
  });
}
