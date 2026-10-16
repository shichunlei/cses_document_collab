import 'dart:io';
import 'dart:ui' as ui;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/controller/collab_controller.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/editor/collab_divider_visual.dart';
import 'package:cses_document_collab/src/editor/collaborative_editor_page.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_divider.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证桌面展示回落、独立补丁/稳定身份、面板交互和原生绘图。
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
  test(
    'legacy size and Number opacity match desktop without normalizing raw props',
    () {
      for (final sample in const [
        ({}, 'full', 'thin', 1.0),
        ({'size': 'thin'}, 'short', 'thin', 1.0),
        ({'size': 'small'}, 'medium', 'thin', 1.0),
        ({'size': 'medium'}, 'long', 'regular', 1.0),
        ({'size': 'large', 'opacity': null}, 'full', 'thick', .1),
        (
          {
            'length': 'short',
            'thickness': 'regular',
            'size': 'large',
            'opacity': '.7',
          },
          'short',
          'regular',
          .7,
        ),
        ({'opacity': 'bad', 'style': 'future-style'}, 'full', 'thin', 1.0),
      ]) {
        final view = CollabDivider(Map<String, dynamic>.from(sample.$1));
        expect(view.length, sample.$2);
        expect(view.thickness, sample.$3);
        expect(view.opacity, sample.$4);
        expect(sample.$1, view.values);
      }
    },
  );
  test(
    'field undo resolves identity after remote reorder and preserves missing/null',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _fixture,
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      expect(
        await changeCollabDividerProperty(state, 'line', 'style', 'wave'),
        isTrue,
      );
      expect(
        changes.last.first.resource!.propertyEdits,
        '{"style":{"value":"wave"}}',
      );
      expect(
        await changeCollabDividerProperty(state, 'line', 'length', 'short'),
        isTrue,
      );
      expect(
        changes.last.first.resource!.propertyEdits,
        '{"length":{"value":"short"}}',
      );
      final updated = adapter.blocks;
      await adapter.replaceFromRemote([updated[1], updated[0]]);
      changes.clear();
      state.undoManager.undo();
      await pumpEventQueue();
      expect(changes.last[1].resource!.propertyEdits, '{"length":{}}');
      expect(CollabDivider(changes.last[1].resource!.values).style, 'wave');
      state.undoManager.undo();
      await pumpEventQueue();
      expect(
        changes.last[1].resource!.propertyEdits,
        '{"style":{"value":null}}',
      );
      state.undoManager.redo();
      await pumpEventQueue();
      expect(CollabDivider(adapter.blocks[1].resource!.values).style, 'wave');
      state.editable = false;
      expect(
        await changeCollabDividerProperty(state, 'line', 'style', 'solid'),
        isFalse,
      );
      state.editable = true;
      await adapter.replaceFromRemote([updated[1]]);
      expect(
        await changeCollabDividerProperty(state, 'line', 'style', 'solid'),
        isFalse,
      );
      state.undoManager.undo();
      await pumpEventQueue();
      expect(adapter.blocks.length, 1);
    },
  );
  test(
    'insert in empty/nested/nonempty text keeps void identity and backspace undo',
    () async {
      for (final nested in [false, true]) {
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: [
            if (nested)
              const CollabEditorBlock(
                id: 'container',
                blockType: 'callout',
                text: '',
              ),
            CollabEditorBlock(
              id: 'source',
              parentId: nested ? 'container' : null,
              blockType: 'paragraph',
              text: '',
            ),
          ],
          onLocalBlocksChanged: (_) {},
        );
        final state = adapter.editorState;
        final landing = await insertCollabDivider(
          state,
          Selection.single(path: nested ? [0, 0] : [0], startOffset: 0),
        );
        expect(landing!.start.path, nested ? [0, 1] : [1]);
        final divider = adapter.blocks.firstWhere(
          (b) => b.blockType == collabDividerType,
        );
        expect(divider.id, isNot('source'));
        expect(divider.replacesId, isNull);
        expect(divider.parentId, nested ? 'container' : null);
        expect(divider.text, isEmpty);
        state.selection = landing;
        expect(await deletePreviousUrlBackedBlock(state), isTrue);
        expect(
          adapter.blocks.any((b) => b.blockType == collabDividerType),
          isFalse,
        );
        state.undoManager.undo();
        await pumpEventQueue();
        expect(
          adapter.blocks.any((b) => b.blockType == collabDividerType),
          isTrue,
        );
        adapter.dispose();
      }
    },
  );
  testWidgets(
    'settings stay open for edits, isolate input, update remote fields and respect preview',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _fixture,
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final controller = _ReadyController(adapter.editorState);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: CollaborativeEditorPage(collab: controller)),
      );
      await tester.pumpAndSettle();
      final state = adapter.editorState;
      state.selection = Selection.single(
        path: [1],
        startOffset: 1,
        endOffset: 3,
      );
      expect(find.byTooltip('更多操作'), findsNothing);
      expect(find.byKey(const ValueKey('block-more-line')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('collab-divider-line')));
      await tester.pumpAndSettle();
      expect(state.selection, isNull);
      expect(
        find.byKey(const ValueKey('collab-divider-settings')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('divider-style-wave')));
      await tester.pumpAndSettle();
      expect(
        CollabDivider(adapter.blocks.first.resource!.values).style,
        'wave',
      );
      expect(
        find.byKey(const ValueKey('collab-divider-settings')),
        findsOneWidget,
      );
      await tester.tap(find.text('花边'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('divider-style-edge-vine')));
      await tester.pumpAndSettle();
      expect(
        CollabDivider(adapter.blocks.first.resource!.values).style,
        'edge-vine',
      );
      await tester.tap(find.byKey(const ValueKey('divider-color-#EF4444')));
      await tester.pumpAndSettle();
      expect(
        CollabDivider(adapter.blocks.first.resource!.values).lineColor,
        '#EF4444',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('divider-length-short')),
      );
      await tester.tap(find.byKey(const ValueKey('divider-length-short')));
      await tester.pumpAndSettle();
      expect(
        CollabDivider(adapter.blocks.first.resource!.values).length,
        'short',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('divider-thickness-thick')),
      );
      await tester.tap(find.byKey(const ValueKey('divider-thickness-thick')));
      await tester.pumpAndSettle();
      expect(
        CollabDivider(adapter.blocks.first.resource!.values).thickness,
        'thick',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('divider-opacity')));
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('divider-opacity')),
      );
      slider.onChanged!(.4);
      slider.onChangeEnd!(.4);
      await tester.pumpAndSettle();
      expect(CollabDivider(adapter.blocks.first.resource!.values).opacity, .4);
      final originalNode = state.getNodeAtPath([0]);
      await adapter.replaceFromRemote([
        CollabEditorBlock(
          id: 'line',
          blockType: 'divider',
          text: '',
          resource: CollabResource.fromValues({
            'style': 'edge-vine',
            'lineColor': '#3B82F6',
            'length': 'medium',
            'thickness': 'thin',
            'opacity': .6,
          }),
        ),
        adapter.blocks[1],
      ]);
      await tester.pumpAndSettle();
      expect(state.getNodeAtPath([0]), same(originalNode));
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('divider-opacity')))
            .value,
        .6,
      );
      await tester.ensureVisible(find.byTooltip('关闭'));
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(
        state.selection,
        Selection.single(path: [1], startOffset: 1, endOffset: 3),
      );
      await tester.tap(find.byKey(const ValueKey('editor-mode-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('collab-divider-line')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('collab-divider-settings')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'clear color shares selection, undo and permission logic with swatches',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _fixture,
        onLocalBlocksChanged: changes.add,
      );
      final controller = _ReadyController(adapter.editorState);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        adapter.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(
        MaterialApp(home: CollaborativeEditorPage(collab: controller)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('collab-divider-line')));
      await tester.pumpAndSettle();
      final clear = find.byKey(const ValueKey('divider-color-clear'));
      final red = find.byKey(const ValueKey('divider-color-#EF4444'));
      await tester.ensureVisible(clear);
      await tester.pumpAndSettle();

      /// 验证 [clearSelected] 和 [redSelected] 的边框与选中语义一致。
      /// [enabled] 默认true，权限变化后同时验证两块可用状态及点击入口。
      void expectSelection(
        bool clearSelected,
        bool redSelected, {
        bool enabled = true,
      }) {
        for (final option in [(clear, clearSelected), (red, redSelected)]) {
          final node = tester.getSemantics(option.$1);
          expect(
            node.flagsCollection.isSelected,
            option.$2 ? ui.Tristate.isTrue : ui.Tristate.isFalse,
          );
          expect(
            node.flagsCollection.isEnabled,
            enabled ? ui.Tristate.isTrue : ui.Tristate.isFalse,
          );
          final box = tester.widget<Container>(
            find
                .descendant(of: option.$1, matching: find.byType(Container))
                .first,
          );
          final decoration = box.decoration! as BoxDecoration;
          final border = decoration.border! as Border;
          expect(
            border.top.color,
            option.$2
                ? Theme.of(tester.element(option.$1)).colorScheme.primary
                : Colors.transparent,
          );
          expect(tester.getSize(option.$1), const Size(36, 36));
          expect(
            tester.widget<InkWell>(option.$1).onTap,
            enabled ? isNotNull : isNull,
          );
        }
      }

      expectSelection(true, false);
      expect(find.byTooltip('清除颜色'), findsOneWidget);
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(
        changes,
        isEmpty,
        reason: 'clearing an unset color must not add history',
      );
      await tester.tap(red);
      await tester.pumpAndSettle();
      expectSelection(false, true);
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expectSelection(true, false);
      expect(adapter.blocks.first.resource!.values['lineColor'], '');
      adapter.editorState.undoManager.undo();
      await tester.pumpAndSettle();
      expectSelection(false, true);
      expect(adapter.blocks.first.resource!.values['lineColor'], '#EF4444');
      adapter.editorState.undoManager.redo();
      await tester.pumpAndSettle();
      expectSelection(true, false);
      await adapter.replaceFromRemote([
        const CollabEditorBlock(
          id: 'line',
          blockType: 'divider',
          text: '',
          resource: CollabResource(
            properties: '{"lineColor":"rgb(239, 68, 68)"}',
          ),
        ),
        _fixture[1],
      ]);
      await tester.pumpAndSettle();
      expectSelection(false, true);
      final count = changes.length;
      await tester.tap(red);
      await tester.pumpAndSettle();
      expect(changes, hasLength(count));
      expect(
        adapter.blocks.first.resource!.values['lineColor'],
        'rgb(239, 68, 68)',
      );
      adapter.editorState.editable = false;
      await tester.pumpAndSettle();
      expectSelection(false, true, enabled: false);
      adapter.editorState.editable = true;
      await tester.pumpAndSettle();
      expectSelection(false, true);
      expect(tester.takeException(), isNull);
    },
  );

  for (final layout in [(390.0, 844.0, 1.0), (320.0, 568.0, 1.5)]) {
    testWidgets(
      'settings header stays pinned with single-line tabs at ${layout.$1}x${layout.$2} and ${layout.$3} text scale',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(layout.$1, layout.$2));
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: _fixture,
          onLocalBlocksChanged: (_) {},
        );
        final controller = _ReadyController(adapter.editorState);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
          adapter.dispose();
          await tester.binding.setSurfaceSize(null);
        });
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(layout.$3)),
              child: child!,
            ),
            home: CollaborativeEditorPage(collab: controller),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('collab-divider-line')));
        await tester.pumpAndSettle();
        final tabs = find.byType(SegmentedButton<int>);
        final initialHeight = tester.getSize(tabs).height;
        final header = find.byKey(const ValueKey('divider-settings-header'));
        final preview = find.byKey(const ValueKey('divider-settings-preview'));
        final content = find.byKey(const ValueKey('divider-settings-content'));
        final close = find.byTooltip('关闭');
        final scrollController = tester
            .widget<SingleChildScrollView>(content)
            .controller!;

        for (final label in ['贴纸胶带', '花边', '线型']) {
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          expect(
            scrollController.offset,
            0,
            reason: 'each tab starts with its first preset',
          );
          expect(tester.getSize(tabs).height, initialHeight);
          final colorMatcher = label == '贴纸胶带' ? findsNothing : findsOneWidget;
          expect(find.text('线色'), colorMatcher);
          expect(
            find.byKey(const ValueKey('divider-color-clear')),
            colorMatcher,
          );
          expect(
            find.byKey(const ValueKey('divider-color-#EF4444')),
            colorMatcher,
          );
          for (final tabLabel in ['线型', '贴纸胶带', '花边']) {
            final paragraph = tester.renderObject<RenderParagraph>(
              find.text(tabLabel),
            );
            expect(
              paragraph.getBoxesForSelection(
                TextSelection(baseOffset: 0, extentOffset: tabLabel.length),
              ),
              hasLength(1),
              reason: '$tabLabel must remain one complete line after selection',
            );
          }
          final tabRect = tester.getRect(tabs);
          final tapeRect = tester.getRect(find.text('贴纸胶带'));
          expect(
            tapeRect.left,
            greaterThanOrEqualTo(tabRect.left + tabRect.width / 3),
          );
          expect(
            tapeRect.right,
            lessThanOrEqualTo(tabRect.left + tabRect.width * 2 / 3),
          );
          final fixedRects = [
            tester.getRect(header),
            tester.getRect(preview),
            tester.getRect(tabs),
            tester.getRect(close),
          ];
          final contentRect = tester.getRect(content);
          final style = switch (label) {
            '贴纸胶带' => 'tape-gradient-blocks',
            '花边' => 'edge-vine',
            _ => 'solid',
          };
          final preset = find.byKey(ValueKey('divider-style-$style'));
          await tester.ensureVisible(preset);
          await tester.tap(preset);
          await tester.pumpAndSettle();
          for (final thickness in ['thin', 'regular', 'thick']) {
            final option = find.byKey(ValueKey('divider-thickness-$thickness'));
            await tester.ensureVisible(option);
            await tester.tap(option);
            await tester.pumpAndSettle();
            expect(
              [
                tester.getRect(header),
                tester.getRect(preview),
                tester.getRect(tabs),
                tester.getRect(close),
              ],
              fixedRects,
              reason:
                  'style and thickness cannot resize the fixed preview slot',
            );
            expect(tester.getRect(content), contentRect);
            final visual = find.descendant(
              of: preview,
              matching: find.byType(CollabDividerVisual),
            );
            final divider = tester.widget<CollabDividerVisual>(visual).divider;
            expect(divider.style, style);
            expect(divider.thickness, thickness);
            final slotRect = tester.getRect(preview);
            final visualRect = tester.getRect(visual);
            expect(visualRect.top, greaterThanOrEqualTo(slotRect.top + 12));
            expect(visualRect.bottom, lessThanOrEqualTo(slotRect.bottom - 12));
            expect(visualRect.center.dy, slotRect.center.dy);
          }
          scrollController.jumpTo(0);
          await tester.pumpAndSettle();
          await tester.dragFrom(
            tester.getTopLeft(content) + const Offset(30, 30),
            const Offset(0, -220),
          );
          await tester.pumpAndSettle();
          if (scrollController.position.maxScrollExtent > 0) {
            expect(scrollController.offset, greaterThan(0));
          }
          await tester.ensureVisible(
            find.byKey(const ValueKey('divider-delete')),
          );
          await tester.pumpAndSettle();
          expect(
            [
              tester.getRect(header),
              tester.getRect(preview),
              tester.getRect(tabs),
              tester.getRect(close),
            ],
            fixedRects,
            reason: 'scrolling settings cannot move the fixed header',
          );
          final deleteCenter = tester.getCenter(
            find.byKey(const ValueKey('divider-delete')),
          );
          final viewport = tester.getRect(content);
          expect(
            viewport.contains(deleteCenter),
            isTrue,
            reason: 'the last setting remains reachable',
          );
          expect(tester.takeException(), isNull);
        }
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('collab-divider-settings')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('more menu inserts divider and lands in following paragraph', (
    tester,
  ) async {
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [
        CollabEditorBlock(id: 'source', blockType: 'paragraph', text: '保留正文'),
      ],
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);
    final controller = _ReadyController(adapter.editorState);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: CollaborativeEditorPage(collab: controller)),
    );
    await tester.pumpAndSettle();
    adapter.editorState.selection = Selection.single(path: [0], startOffset: 2);
    final page = tester.element(
      find.byKey(const ValueKey('collaborative-editor-page')),
    );
    var completed = false;
    final action = showEditorAddBlockSheet(
      page,
      adapter.editorState,
    ).then((_) => completed = true);
    await tester.pumpAndSettle();
    final entry = find.byKey(const ValueKey('editor-shortcut-divider'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    for (var i = 0; i < 8 && !completed; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(completed, isTrue);
    await action;
    expect(adapter.blocks.map((b) => b.blockType), [
      'paragraph',
      'divider',
      'paragraph',
    ]);
    expect(adapter.blocks.first.text, '保留正文');
    expect(adapter.editorState.selection!.start.path, [2]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 150));
  });
  testWidgets('all desktop styles paint at narrow and mobile widths', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: GridView(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisExtent: 84,
                  mainAxisSpacing: 4,
                ),
                children: [
                  for (final e in collabDividerStyles.entries)
                    Column(
                      children: [
                        Text(
                          e.value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        CollabDividerVisual(
                          divider: CollabDivider({
                            'style': e.key,
                            'lineColor': '#607D9B',
                            'thickness': 'regular',
                          }),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final rgba = bytes!.buffer.asUint8List();
      for (final element in find.byType(CollabDividerVisual).evaluate()) {
        final box = element.findRenderObject()! as RenderBox;
        final rect =
            box.localToGlobal(Offset.zero, ancestor: boundary) & box.size;
        var ink = 0;
        for (
          var y = rect.top.ceil();
          y < rect.bottom.floor() && y < image.height;
          y++
        ) {
          for (
            var x = rect.left.ceil();
            x < rect.right.floor() && x < image.width;
            x++
          ) {
            if (rgba[(y * image.width + x) * 4 + 3] > 0) ink++;
          }
        }
        expect(
          ink,
          greaterThan(0),
          reason:
              'Missing artwork: ${(element.widget as CollabDividerVisual).divider.style}',
        );
      }
      image.dispose();
    });
    const path = String.fromEnvironment('DIVIDER_PREVIEW_PATH');
    if (path.isNotEmpty) {
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(path).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.binding.setSurfaceSize(const Size(160, 1000));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

/// 样本保留显式 style:null 与缺失 length，用于精确历史恢复。
const _fixture = [
  CollabEditorBlock(
    id: 'line',
    blockType: 'divider',
    text: '',
    resource: CollabResource(properties: '{"style":null}'),
  ),
  CollabEditorBlock(id: 'tail', blockType: 'paragraph', text: '后置正文'),
];

/// 仅借用测试编辑器，不初始化本地原生引擎。
class _ReadyController extends CollabController {
  /// [state] 由测试创建/销毁，控制器不接管所有权。
  _ReadyController(this.state) : super.localDraft(databasePath: '/unused');

  /// 借用的测试编辑器，由用例释放。
  final EditorState state;

  /// 返回借用编辑器。
  @override
  EditorState get editorState => state;

  /// 样本已就绪。
  @override
  bool get initialized => true;

  /// 测试页面始终具备编辑权限，预览由页面控制。
  @override
  bool get canEdit => true;
}
