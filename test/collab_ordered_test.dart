import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:cses_mobile_collab_demo/src/collab/collab_ordered.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_ordered_marker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 验证正式编号投影、桌面预设和 AppFlowy 标记扩展，不连接真实服务或写业务文档。
void main() {
  testWidgets('ordered marker exposes numbering commands only while editable', (
    tester,
  ) async {
    final changes = <List<CollabEditorBlock>>[];
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [
        CollabEditorBlock(
          id: 'item',
          blockType: 'numbered_list',
          text: 'item',
          ordered: CollabOrdered(order: 2, numbering: '{"start":3}'),
        ),
      ],
      onLocalBlocksChanged: changes.add,
    );
    addTearDown(adapter.dispose);
    adapter.editorState.editorStyle = const EditorStyle.mobile();
    await tester.pumpWidget(
      MaterialApp(
        home: Provider<EditorState>.value(
          value: adapter.editorState,
          child: Builder(
            builder: (context) => Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 200, top: 120),
                child: SizedBox(
                  width: 36,
                  height: 24,
                  child: buildCollabOrderedMarker(
                    context,
                    adapter.editorState.document.first!,
                    TextDirection.ltr,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('3.'));
    await tester.pumpAndSettle();
    expect(find.text('继续编号'), findsOneWidget);
    expect(find.text('重新编号'), findsOneWidget);
    final menu = find.byKey(const ValueKey('collab-numbering-menu'));
    expect(find.byType(CheckedPopupMenuItem<bool>), findsNothing);
    final menuOrigin = tester.getTopLeft(menu);
    expect(menuOrigin.dx, inInclusiveRange(190, 240));
    expect(menuOrigin.dy, inInclusiveRange(110, 160));
    expect(tester.getSize(menu).width, lessThanOrEqualTo(110));
    expect(tester.getSize(menu).height, lessThanOrEqualTo(80));
    expect(
      tester.widget<Text>(find.text('重新编号')).style!.color,
      const Color(0xFF9CA3AF),
    );
    await tester.tap(find.byKey(const ValueKey('collab-numbering-restart')));
    await tester.pumpAndSettle();
    expect(changes, hasLength(1));
    expect(jsonDecode(changes.single.single.ordered!.numberingEdit!), {
      'start': 1,
      'continuePrevious': false,
    });
    await tester.tap(find.text('3.'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('collab-numbering-continue')));
    await tester.pumpAndSettle();
    expect(changes, hasLength(2));
    expect(jsonDecode(changes.last.single.ordered!.numberingEdit!), {
      'start': 0,
      'continuePrevious': true,
    });
    adapter.editorState.editable = false;
    await tester.tap(find.text('3.'));
    await tester.pumpAndSettle();
    expect(find.text('继续编号'), findsNothing);
    expect(changes, hasLength(2));
  });

  testWidgets(
    'custom menu avoids screen edges and keyboard, cancel keeps selection',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'item',
            blockType: 'numbered_list',
            text: 'item',
            ordered: CollabOrdered(order: 0),
          ),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.editorStyle = const EditorStyle.mobile();
      final selection = Selection.single(path: [0], startOffset: 2);
      state.selection = selection;
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(viewInsets: const EdgeInsets.only(bottom: 300)),
            child: child!,
          ),
          home: Provider<EditorState>.value(
            value: state,
            child: Focus(
              focusNode: focus,
              autofocus: true,
              child: Builder(
                builder: (context) => Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 310),
                    child: SizedBox(
                      width: 36,
                      height: 24,
                      child: buildCollabOrderedMarker(
                        context,
                        state.document.first!,
                        TextDirection.ltr,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final markerTop = tester.getTopLeft(find.text('1.')).dy;
      await tester.tap(find.text('1.'));
      await tester.pumpAndSettle();
      final menu = find.byKey(const ValueKey('collab-numbering-menu'));
      final rect = tester.getRect(menu);
      expect(rect.right, lessThanOrEqualTo(382));
      expect(rect.bottom, lessThan(markerTop));
      expect(rect.top, greaterThanOrEqualTo(8));
      expect(focus.hasFocus, isTrue);
      expect(state.selection, selection);
      await tester.tapAt(const Offset(20, 100));
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(changes, isEmpty);
      expect(state.selection, selection);

      await tester.tap(find.text('1.'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(changes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'numbering undo follows stable target after remote reorder and ignores deletion',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'a',
            blockType: 'numbered_list',
            text: 'a',
            ordered: CollabOrdered(order: 0),
          ),
          CollabEditorBlock(
            id: 'b',
            blockType: 'numbered_list',
            text: 'b',
            ordered: CollabOrdered(order: 1),
          ),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      await changeCollabOrderedNumbering(
        adapter.editorState,
        'a',
        restart: true,
      );
      await adapter.replaceFromRemote(adapter.blocks.reversed.toList());
      adapter.editorState.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(changes.last.last.id, 'a');
      expect(changes.last.last.ordered!.numberingEdit, '{}');
      expect(changes.last.first.ordered!.numberingEdit, isNull);
      adapter.editorState.undoManager.redo();
      await Future<void>.delayed(Duration.zero);
      expect(jsonDecode(changes.last.last.ordered!.numberingEdit!)['start'], 1);
      await adapter.replaceFromRemote([adapter.blocks.first]);
      final count = changes.length;
      adapter.editorState.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(changes, hasLength(count));
      expect(adapter.blocks.single.id, 'b');
      expect(adapter.blocks.single.ordered!.numbering, '{}');
    },
  );

  test(
    'numbering transaction preserves custom start in undo and redo',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'a',
            blockType: 'numbered_list',
            text: 'item',
            ordered: CollabOrdered(
              order: 4,
              start: 5,
              markerStyle: 'a2',
              numbering: '{"start":5,"continuePrevious":null}',
            ),
          ),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      expect(
        await changeCollabOrderedNumbering(state, 'a', restart: true),
        isTrue,
      );
      expect(jsonDecode(changes.last.single.ordered!.numberingEdit!), {
        'start': 1,
        'continuePrevious': false,
      });
      // 模拟原生确认：派生序号改变但不写入本地撤销历史。
      await adapter.replaceFromRemote(const [
        CollabEditorBlock(
          id: 'a',
          blockType: 'numbered_list',
          text: 'remote text',
          ordered: CollabOrdered(
            order: 0,
            start: 1,
            markerStyle: 'r2',
            numbering: '{"continuePrevious":false,"start":1}',
          ),
        ),
      ]);
      state.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(jsonDecode(changes.last.single.ordered!.numberingEdit!), {
        'start': 5,
        'continuePrevious': null,
      });
      expect(adapter.text, 'remote text');
      expect(changes.last.single.ordered!.markerStyle, 'r2');
      state.undoManager.redo();
      await Future<void>.delayed(Duration.zero);
      expect(jsonDecode(changes.last.single.ordered!.numberingEdit!), {
        'start': 1,
        'continuePrevious': false,
      });
      expect(
        await changeCollabOrderedNumbering(state, 'a', restart: true),
        isFalse,
      );
      expect(adapter.blocks.single.ordered!.numberingEdit, isNull);
      final transaction = state.transaction
        ..insertText(state.document.first!, 0, 'x');
      await state.apply(transaction);
      expect(changes.last.single.ordered!.numberingEdit, isNull);
      expect(changes.last.single.id, 'a');
      expect(changes.last.single.ordered!.markerStyle, 'r2');
    },
  );

  test(
    'numbering resolves current identity and rejects deleted readonly and draft targets',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'a',
            blockType: 'numbered_list',
            text: 'a',
            ordered: CollabOrdered(order: 0),
          ),
          CollabEditorBlock(
            id: 'b',
            blockType: 'numbered_list',
            text: 'b',
            ordered: CollabOrdered(order: 1),
          ),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      await adapter.replaceFromRemote(adapter.blocks.reversed.toList());
      expect(
        await changeCollabOrderedNumbering(
          adapter.editorState,
          'a',
          restart: false,
        ),
        isTrue,
      );
      expect(changes.last.last.ordered!.numberingEdit, isNotNull);
      expect(changes.last.first.ordered!.numberingEdit, isNull);
      await adapter.replaceFromRemote(const [
        CollabEditorBlock(id: 'b', blockType: 'paragraph', text: 'b'),
        CollabEditorBlock(
          id: 'draft',
          blockType: 'numbered_list',
          text: 'draft',
        ),
      ]);
      expect(
        await changeCollabOrderedNumbering(
          adapter.editorState,
          'a',
          restart: true,
        ),
        isFalse,
      );
      expect(
        await changeCollabOrderedNumbering(
          adapter.editorState,
          'b',
          restart: true,
        ),
        isFalse,
      );
      expect(
        await changeCollabOrderedNumbering(
          adapter.editorState,
          'draft',
          restart: true,
        ),
        isFalse,
      );
      adapter.editorState.editable = false;
      expect(
        await changeCollabOrderedNumbering(
          adapter.editorState,
          'draft',
          restart: true,
        ),
        isFalse,
      );
      expect(changes, hasLength(1));
    },
  );

  test('desktop marker presets and depth fallback match native semantics', () {
    const expected = {
      'n1': '2.',
      'n2': '2)',
      'n3': '（2）',
      'n4': '2、',
      'n5': '02.',
      'a1': 'b.',
      'a2': 'B.',
      'r1': 'ii.',
      'r2': 'II.',
      'c1': '二、',
      'c2': '贰、',
      'o1': '2',
    };
    for (final entry in expected.entries) {
      expect(
        CollabOrdered(order: 1, markerStyle: entry.key).marker(0),
        entry.value,
      );
    }
    expect(const CollabOrdered(order: 26).marker(1), 'aa.');
    expect(const CollabOrdered(order: 8).marker(2), 'IX.');
    expect(
      const CollabOrdered(order: 8, markerStyle: 'future-style').marker(2),
      'IX.',
    );
    expect(
      const CollabOrdered(order: 4000, markerStyle: 'r2').marker(0),
      '4001.',
    );
    expect(const CollabOrdered(order: 4000).marker(2), 'MMMMI.');
    expect(
      const CollabOrdered(order: 1000, markerStyle: 'c1').marker(0),
      '一千零一、',
    );
    const value = CollabOrdered(
      order: 4,
      start: 5,
      heading: 2,
      markerStyle: 'a2',
      needsRepair: true,
    );
    expect(CollabOrdered.fromJson(value.toJson()), value);
  });

  test(
    'remote ordered props patch existing nodes without echo or losing text',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'a',
            blockType: 'numbered_list',
            text: 'item',
            ordered: CollabOrdered(order: 0),
          ),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      final original = adapter.editorState.document.first!;
      await adapter.replaceFromRemote(const [
        CollabEditorBlock(
          id: 'a',
          blockType: 'numbered_list',
          text: 'item',
          ordered: CollabOrdered(order: 4, start: 5, markerStyle: 'a2'),
        ),
      ]);
      expect(adapter.editorState.document.first, same(original));
      expect(adapter.blocks.single.ordered?.order, 4);
      expect(adapter.text, 'item');
      expect(changes, isEmpty);
    },
  );

  testWidgets(
    'mobile markers use shared numbering across intervening paragraphs',
    (tester) async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'a',
            blockType: 'numbered_list',
            text: 'first',
            ordered: CollabOrdered(order: 0),
          ),
          CollabEditorBlock(id: 'gap', blockType: 'paragraph', text: 'gap'),
          CollabEditorBlock(
            id: 'b',
            blockType: 'numbered_list',
            text: 'second',
            ordered: CollabOrdered(order: 1),
          ),
          CollabEditorBlock(
            id: 'c',
            blockType: 'numbered_list',
            text: 'third',
            ordered: CollabOrdered(order: 2),
          ),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      adapter.editorState.editorStyle = const EditorStyle.mobile();
      await tester.pumpWidget(
        MaterialApp(
          home: Provider<EditorState>.value(
            value: adapter.editorState,
            child: Builder(
              builder: (context) => Column(
                children: [
                  for (final node
                      in adapter.editorState.document.root.children.where(
                        (n) => n.type == NumberedListBlockKeys.type,
                      ))
                    buildCollabOrderedMarker(context, node, TextDirection.ltr),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('1.'), findsOneWidget);
      expect(find.text('2.'), findsOneWidget);
      expect(find.text('3.'), findsOneWidget);
    },
  );
}
