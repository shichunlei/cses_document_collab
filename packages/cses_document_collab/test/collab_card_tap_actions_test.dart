import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_date_card_block.dart';
import 'package:cses_document_collab/src/editor/collab_block_lock_chrome.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/model/collab_block_lock.dart';
import 'package:cses_document_collab/src/editor/collab_person_card_block.dart';
import 'package:cses_document_collab/src/editor/collab_weather_block.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/ui/modal/collab_bottom_sheet.dart';
import 'package:cses_document_collab/src/ui/modal/collab_card_frame.dart';
import 'package:cses_document_collab/src/ui/modal/collab_editor_display_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证无额外外框的三类卡片整卡操作、预览展示和过期菜单保护。
void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('keyboardHeightEventChannel'),
      MockStreamHandler.inline(onListen: (_, events) => events.success(0.0)),
    );
  });
  for (final (kind, label) in const [('person-card', '人员'), ('weather', '天气'), ('date-card', '日期')]) {
    for (final authoredWidth in [180.0, 600.0]) {
      testWidgets('$kind lock follows fitted card at authored width $authoredWidth', (tester) async {
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: [
            CollabEditorBlock(
              id: 'card',
              blockType: kind,
              text: '',
              resource: CollabResource.fromValues({
                'date': '2026-10-26T09:00',
                'style': switch (kind) {
                  'weather' => 'stack',
                  'date-card' => 'minibar',
                  _ => 'row',
                },
                'width': authoredWidth,
                'height': 280.0,
              }),
            ),
          ],
          onLocalBlocksChanged: (_) {},
        );
        final editor = adapter.editorState;
        final locks = CollabBlockLocks(
          editor: editor,
          userId: 'u1',
          canUnlock: (_) => false,
          commit: (_, _, _) async {},
        );
        editor.blockDecorator = (context, node, child) => decorateCollabBlockLock(context, editor, node, child);
        locks.update(const [CollabBlockLockState(blockId: 'card', sourceId: 'card', ownerId: 'u1')]);
        final snapshot = editor.document.toJson();
        await _mount(tester, adapter);
        final surface = tester.getRect(find.byKey(ValueKey('collab-$kind-surface')));
        final badge = find.byKey(const ValueKey('block-lock-badge-card'));
        expect(badge, findsOneWidget);
        final rect = tester.getRect(badge);
        expect(rect.top, closeTo(surface.top - 5, .01));
        expect(rect.right, closeTo(surface.right + 5, .01));
        expect(rect.width, closeTo(14, .01));
        if (authoredWidth == 180) {
          expect(surface.right, lessThan(tester.getRect(_cardSurface(label)).right - 20));
        }
        RenderObject child = tester.renderObject(badge);
        while (child.parent != null) {
          final parent = child.parent!;
          final clip = parent.describeApproximatePaintClip(child);
          if (clip != null) {
            final visible = MatrixUtils.transformRect(parent.getTransformTo(null), clip).inflate(.01);
            expect(visible.contains(rect.topLeft), isTrue, reason: '$parent clips lock');
            expect(visible.contains(rect.bottomRight), isTrue, reason: '$parent clips lock');
          }
          child = parent;
        }
        await tester.tap(_cardSurface(label));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('block-lock-card')), findsOneWidget);
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        locks.update(const [CollabBlockLockState(blockId: 'card')]);
        await tester.pumpAndSettle();
        expect(badge, findsNothing);
        expect(editor.document.toJson(), snapshot);
        expect(editor.undoManager.undoStack, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        locks.dispose();
        adapter.dispose();
      });
    }
    testWidgets('$kind body opens settings and delete preserves independent undo', (tester) async {
      final adapter = _adapter(kind);
      await _mount(tester, adapter);
      expect(find.byType(CollabCardFrame), findsNothing);
      expect(find.byTooltip('更多操作'), findsNothing);
      final card = _cardSurface(label);
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.byType(CollabBottomSheet), findsOneWidget);
      await tester.tap(find.text('$label设置'));
      await tester.pumpAndSettle();
      expect(find.byType(CollabBottomSheet), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(adapter.editorState.undoManager.undoStack, isEmpty);
      await tester.tap(card);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除$label卡片'));
      await tester.pumpAndSettle();
      expect(adapter.blocks.any((block) => block.id == 'card'), isFalse);
      adapter.editorState.undoManager.undo();
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.id, 'card');
      expect(adapter.blocks.first.blockType, kind);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      adapter.dispose();
    });
    for (final preview in [false, true]) {
      testWidgets('$kind remains visible and inert in ${preview ? 'preview' : 'readonly'}', (tester) async {
        final adapter = _adapter(kind);
        adapter.editorState.editable = false;
        await _mount(tester, adapter, preview: preview);
        final card = _cardSurface(label);
        expect(card, findsOneWidget);
        expect(tester.getSize(card).height, greaterThan(0));
        expect(find.byType(CollabCardFrame), findsNothing);
        await tester.tap(card);
        await tester.pumpAndSettle();
        expect(find.byType(CollabBottomSheet), findsNothing);
        expect(adapter.blocks.first.id, 'card');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        adapter.dispose();
      });
    }
    testWidgets('$kind repeated taps and revoke/restore cannot reuse old delete menu', (tester) async {
      final adapter = _adapter(kind);
      await _mount(tester, adapter);
      final card = _cardSurface(label);
      await tester.tap(card);
      await tester.tap(card, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(CollabBottomSheet), findsOneWidget);
      adapter.editorState.editable = false;
      adapter.editorState.editable = true;
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除$label卡片'));
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.id, 'card');
      expect(adapter.editorState.undoManager.undoStack, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      adapter.dispose();
    });
  }
}

/// 创建由测试持有并释放的[kind]卡片编辑器；天气不注入网络查询。
AppFlowyBlockEditorAdapter _adapter(String kind) => AppFlowyBlockEditorAdapter(
  initialBlocks: [
    CollabEditorBlock(
      id: 'card',
      blockType: kind,
      text: '',
      resource: CollabResource.fromValues({'date': '2026-10-26T09:00'}),
    ),
    const CollabEditorBlock(id: 'tail', blockType: 'paragraph', text: '保留正文'),
  ],
  onLocalBlocksChanged: (_) {},
);

/// 以[tester]挂载借用的[adapter]，手机宽度320；[preview]默认false，启用时隐藏编辑入口。
Future<void> _mount(WidgetTester tester, AppFlowyBlockEditorAdapter adapter, {bool preview = false}) async {
  await tester.binding.setSurfaceSize(const Size(320, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        AppFlowyEditorLocalizations.delegate,
      ],
      home: Scaffold(
        body: CollabEditorDisplayScope(
          services: const CollabHostServices(),
          preview: preview,
          child: AppFlowyEditor(
            editorState: adapter.editorState,
            editable: adapter.editorState.editable,
            editorStyle: const EditorStyle.mobile(),
            blockComponentBuilders: {
              ...standardBlockComponentBuilderMap,
              'person-card': CollabPersonCardBlockComponentBuilder(),
              'weather': CollabWeatherBlockComponentBuilder(),
              'date-card': CollabDateCardBlockComponentBuilder(),
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 按[label]查找卡片语义外层，不依赖天气和日期子内容合并后的朗读文本。
Finder _cardSurface(String label) =>
    find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == '$label卡片操作');
