import 'fixtures.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_page.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_store.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_ruled_content.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 页面回归使用的可失败持久快照存储。
class _Store implements JournalStore {
  /// 最近成功保存的快照。
  JournalDraft? value = threeSectionDraft(DateTime(2026, 10, 22));

  /// true模拟磁盘不可写，不覆盖旧快照。
  bool fail = false;

  /// 读取当前快照。
  @override
  Future<JournalDraft?> read() async => value;

  /// 保存[draft]或模拟写入失败。
  @override
  Future<void> write(JournalDraft draft) async {
    if (fail) throw const FileSystemException('full');
    value = draft;
  }
}

/// 在测试界面打开借用[store]的独立路由，[scale]为系统字号缩放；返回后可恢复同一草稿。
Widget _app(_Store store, {double scale = 1}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => Navigator.of(context).push<void>(
          MaterialPageRoute(builder: (_) => LocalJournalPage(store: store)),
        ),
        child: const Text('打开日记'),
      ),
    ),
  ),
);

/// 从[tester]读取当前渲染中的编辑会话，仅借用不负责释放。
EditorState _state(WidgetTester tester) =>
    tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;

/// 验证真实文字排版横线、编辑/预览一致、日期选择、退出保存与保存失败恢复。
void main() {
  for (final sample in [(390.0, 1.0), (280.0, 2.0)]) {
    testWidgets(
      'same paper layout in edit and preview at ${sample.$1}/${sample.$2}',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(sample.$1, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final store = _Store()
          ..value = threeSectionDraft(DateTime(2026, 10, 22));
        await tester.pumpWidget(_app(store, scale: sample.$2));
        await tester.tap(find.text('打开日记'));
        await tester.pumpAndSettle();
        final state = _state(tester);
        final text = List.filled(
          6,
          '今天完成了重要目标，也记录下过程中值得坚持的方法。换一行继续书写，横线应始终跟随实际文字布局。',
        ).join();
        await state.apply(
          state.transaction..insertText(state.getNodeAtPath([0, 0])!, 0, text),
        );
        await tester.pumpAndSettle();
        expect(find.text('今日记录'), findsOneWidget);
        expect(
          state.document.root.children.map((n) => n.attributes['section']),
          ['record', 'reflection', 'self-check'],
        );

        final editLines = tester
            .renderObjectList<RenderJournalRules>(
              find.descendant(
                of: find.byKey(const ValueKey('journal-section-record')),
                matching: find.byType(JournalRuledContent),
              ),
            )
            .map((r) => r.debugLineOffsets)
            .toList();
        expect(editLines.any((lines) => lines.length > 1), isTrue);
        final editorWidth = tester.getSize(find.byType(JournalSurface)).width;
        await tester.tap(find.byKey(const ValueKey('journal-preview')));
        await tester.pumpAndSettle();
        expect(_state(tester).editable, isFalse);
        expect(
          _state(tester).getNodeAtPath([0, 0])!.delta!.toPlainText(),
          text,
        );
        final previewLines = tester
            .renderObjectList<RenderJournalRules>(
              find.descendant(
                of: find.byKey(const ValueKey('journal-section-record')),
                matching: find.byType(JournalRuledContent),
              ),
            )
            .map((r) => r.debugLineOffsets)
            .toList();
        expect(previewLines, editLines);
        expect(tester.getSize(find.byType(JournalSurface)).width, editorWidth);
        expect(tester.takeException(), isNull);
        final before = tester.getTopLeft(find.text('今日成果')).dy;
        await tester.drag(find.byType(AppFlowyEditor), const Offset(0, -500));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(find.text('今日成果')).dy, lessThan(before));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'date changes persist and back waits for save before restoring the same sections',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = _Store();
      await tester.pumpWidget(_app(store));
      await tester.tap(find.text('打开日记'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('journal-date')));
      await tester.pumpAndSettle();
      tester
          .widget<CalendarDatePicker>(
            find.byKey(const ValueKey('journal-calendar')),
          )
          .onDateChanged(DateTime(2026, 10, 21));
      await tester.pumpAndSettle();
      final state = _state(tester);
      await state.apply(
        state.transaction
          ..insertText(state.getNodeAtPath([1, 0])!, 0, '离线感悟会恢复'),
      );
      store.fail = true;
      await tester.tap(find.byKey(const ValueKey('journal-back')));
      await tester.pumpAndSettle();
      expect(find.byType(LocalJournalPage), findsOneWidget);
      expect(find.byKey(const ValueKey('journal-retry-save')), findsOneWidget);
      expect(
        _state(tester).getNodeAtPath([1, 0])!.delta!.toPlainText(),
        '离线感悟会恢复',
      );
      store.fail = false;
      await tester.tap(find.byKey(const ValueKey('journal-back')));
      await tester.pumpAndSettle();
      expect(find.byType(LocalJournalPage), findsNothing);
      expect(store.value!.date, '2026-10-21');
      await tester.tap(find.text('打开日记'));
      await tester.pumpAndSettle();
      expect(
        _state(tester).getNodeAtPath([1, 0])!.delta!.toPlainText(),
        '离线感悟会恢复',
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == '记录日期 2026-10-21',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('paper screenshot with all three sections', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = _Store()..value = threeSectionDraft(DateTime(2026, 10, 22));
    const capture = GlobalObjectKey('journal-capture');
    await tester.pumpWidget(RepaintBoundary(key: capture, child: _app(store)));
    await tester.tap(find.text('打开日记'));
    await tester.pumpAndSettle();
    final state = _state(tester);
    for (var i = 0; i < 3; i++) {
      await state.apply(
        state.transaction..insertText(
          state.getNodeAtPath([i, 0])!,
          0,
          ['今天完成了重要目标，记录每一步成长。', '耐心把一件小事做好。', '今天的目标完成了吗？还有什么可以改进？'][i],
        ),
      );
    }
    await tester.pumpAndSettle();
    if (const bool.fromEnvironment('SAVE_JOURNAL_SCREENSHOTS')) {
      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List();
        await File(
          'docs/verification/offline-journal-20261022/host-editor-layout.png',
        ).writeAsBytes(bytes);
        image.dispose();
      });
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
