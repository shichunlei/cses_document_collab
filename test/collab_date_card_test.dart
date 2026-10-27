import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/blockcraft_json_codec.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_date_card_settings.dart';
import 'package:cses_document_collab/src/editor/core/document_editor_controller.dart';
import 'package:cses_document_collab/src/model/collab_block_lock.dart';
import 'package:cses_document_collab/src/model/collab_date_card.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/ui/modal/collab_date_card_visual.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'date_card_settings_test_utils.dart';

/// 日期契约、正式字段补丁、历史、JSON交换及移动设置会话回归。
void main() {
  test('date is a frozen calendar day and missing defaults never mutate props', () {
    final props = <String, dynamic>{'date': '2024-02-29T23:59:00-12:00', 'style': 'future', 'format': 'future'};
    final card = CollabDateCard(props);
    expect(card.date, DateTime(2024, 2, 29));
    expect(card.style, 'calendar');
    expect(card.format, 'full');
    expect(props['style'], 'future');
    expect(CollabDateCard({'date': '2024-02-31'}).date.day, DateTime.now().day);
    expect(dateCardIsoDate(DateTime(2026, 10, 25, 9, 3)), '2026-10-25T09:03');
    expect(dateCardSize('calendar', 'full'), (width: 168.0, height: 144.752));
    expect(dateCardSize('flip', 'min').height, lessThan(dateCardSize('flip', 'full').height));
  });

  test('atomic field edits undo by identity after reorder without losing other fields', () async {
    final published = <List<CollabEditorBlock>>[];
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: published.add);
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    expect(await changeCollabDateCardProperties(state, 'date', {'style': 'pill', 'format': 'min'}), isTrue);
    expect(jsonDecode(published.last.first.resource!.propertyEdits!), {
      'style': {'value': 'pill'},
      'format': {'value': 'min'},
    });
    final updated = adapter.blocks;
    await adapter.replaceFromRemote([updated[1], updated[0]]);
    published.clear();
    state.undoManager.undo();
    await pumpEventQueue();
    final card = adapter.blocks.last.resource!.values;
    expect(card['style'], 'calendar');
    expect(card.containsKey('format'), isFalse);
    expect(card['date'], '2026-10-25T09:30');
    expect(card['future'], {'preserve': true});
    state.undoManager.redo();
    await pumpEventQueue();
    expect(adapter.blocks.last.resource!.values['style'], 'pill');
    expect(adapter.blocks.last.text, isEmpty);
  });

  test('insert freezes date; backspace and undo restore the same card', () async {
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [CollabEditorBlock(id: 'p', blockType: 'paragraph', text: '')],
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    final landing = await insertCollabDateCard(state, Selection.single(path: [0], startOffset: 0));
    expect(landing!.start.path, [1]);
    final inserted = adapter.blocks.first;
    expect(inserted.blockType, 'date-card');
    expect(inserted.resource!.values['date'], startsWith(dateCardIsoDate(DateTime.now()).substring(0, 10)));
    expect(state.document.root.children.first.delta, isNull);
    state.selection = landing;
    expect(await deletePreviousUrlBackedBlock(state), isTrue);
    expect(adapter.blocks.any((b) => b.id == inserted.id), isFalse);
    state.undoManager.undo();
    await pumpEventQueue();
    expect(adapter.blocks.first.id, inserted.id);
    expect(adapter.blocks.first.resource!.values, inserted.resource!.values);
    expect(await insertCollabDateCard(state, Selection.single(path: [1], startOffset: 0, endOffset: 1)), isNull);
  });

  test('locks and invalid properties reject writes and insertion', () async {
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: (_) {});
    final state = adapter.editorState;
    final locks = CollabBlockLocks(editor: state, userId: 'u1', canUnlock: (_) => false, commit: (_, _, _) async {});
    addTearDown(() {
      locks.dispose();
      adapter.dispose();
    });
    locks.update(const [CollabBlockLockState(blockId: 'date', sourceId: 'date', ownerId: 'u2')]);
    expect(await changeCollabDateCardProperty(state, 'date', 'style', 'pill'), isFalse);
    expect(await insertCollabDateCard(state, Selection.single(path: [0], startOffset: 0)), isNull);
    for (final pair in [('style', 'future'), ('format', false), ('width', 0), ('url', 'https://example.test')]) {
      expect(await changeCollabDateCardProperty(state, 'date', pair.$1, pair.$2), isFalse);
    }
  });

  test('JSON imports a native date node and cleared fields stay absent on export', () async {
    final fixture =
        jsonDecode(await File('rust/tests/fixtures/blockcraft-date-card.json').readAsString()) as Map<String, dynamic>;
    fixture['children'] = [(fixture['children'] as List).first];
    final document = BlockCraftJsonCodec.decode(fixture);
    expect(document.root.children.single.type, 'date-card');
    final owner = DocumentEditorController(document: document);
    addTearDown(owner.close);
    await changeCollabDateCardProperty(owner.editorState, 'date-0', 'fg', null);
    final exported = BlockCraftJsonCodec.encode(owner.editorState.document);
    final props = (exported['children'] as List).first['props'] as Map;
    expect(props.containsKey('fg'), isFalse);
    expect(props['date'], '2026-10-25T09:30');
    expect(props['futureProp'], {'preserve': true});
    expect((exported['children'] as List).first['meta']['audit'], 'desktop');
  });

  for (final scale in [1.0, 2.2]) {
    testWidgets('all style/format combinations fit 280px at text scale $scale', (tester) async {
      for (final style in collabDateCardStyles.keys) {
        for (final format in collabDateCardFormats.keys) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: SizedBox(
                    width: 280,
                    child: CollabDateCardVisual(
                      card: CollabDateCard({
                        'style': style,
                        'format': format,
                        'date': '2026-10-25T09:30',
                        'bw': '3px double',
                        'fg': '#416d57',
                        'bg': '#fffefa',
                        'width': 600,
                        'height': 400,
                      }),
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull, reason: '$style/$format');
          expect(tester.getSize(find.byType(CollabDateCardVisual)).width, 280);
        }
      }
    });
  }

  testWidgets('settings preview cancels; apply is one undo step and preserves date', (tester) async {
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: (_) {});
    final state = adapter.editorState;
    await _settingsHost(tester, state);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await chooseDateCardStyle(tester, 'pill');
    await tester.pumpAndSettle();
    expect(adapter.blocks.first.resource!.values['style'], 'calendar');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(state.undoManager.undoStack.isEmpty, isTrue);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await chooseDateCardStyle(tester, 'pill');
    await Scrollable.ensureVisible(tester.element(find.text('不含星期')), alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(find.text('不含星期'));
    await tester.tap(find.byKey(const ValueKey('date-card-apply')));
    await tester.pumpAndSettle();
    expect(adapter.blocks.first.resource!.values['style'], 'pill');
    expect(adapter.blocks.first.resource!.values['format'], 'noWeek');
    expect(adapter.blocks.first.resource!.values['date'], '2026-10-25T09:30');
    expect(state.undoManager.undoStack.isNonEmpty, isTrue);
    state.undoManager.undo();
    await tester.pump();
    expect(adapter.blocks.first.resource!.values['style'], 'calendar');
    expect(state.undoManager.undoStack.isEmpty, isTrue);
    await tester.pumpWidget(const SizedBox());
    adapter.dispose();
  });

  testWidgets('remote update invalidates a dirty draft without overwriting the remote value', (tester) async {
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: (_) {});
    await _settingsHost(tester, adapter.editorState);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await chooseDateCardStyle(tester, 'pill');
    final current = adapter.blocks;
    await adapter.replaceFromRemote([
      CollabEditorBlock(
        id: 'date',
        blockType: 'date-card',
        text: '',
        resource: CollabResource.fromValues({...current.first.resource!.values, 'format': 'noWeek'}),
      ),
      current.last,
    ]);
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('date-card-apply'))).onPressed, isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(adapter.blocks.first.resource!.values['style'], 'calendar');
    expect(adapter.blocks.first.resource!.values['format'], 'noWeek');
    await tester.pumpWidget(const SizedBox());
    adapter.dispose();
  });

  testWidgets('lock then unlock cannot reactivate an old date draft', (tester) async {
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: (_) {});
    final locks = CollabBlockLocks(
      editor: adapter.editorState,
      userId: 'u1',
      canUnlock: (_) => false,
      commit: (_, _, _) async {},
    );
    locks.update(const [CollabBlockLockState(blockId: 'date')]);
    await _settingsHost(tester, adapter.editorState);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await chooseDateCardStyle(tester, 'pill');
    locks.update(const [CollabBlockLockState(blockId: 'date', sourceId: 'date', ownerId: 'u2')]);
    locks.update(const [CollabBlockLockState(blockId: 'date')]);
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('date-card-apply'))).onPressed, isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(adapter.blocks.first.resource!.values['style'], 'calendar');
    await tester.pumpWidget(const SizedBox());
    locks.dispose();
    adapter.dispose();
  });

  testWidgets('gallery retains twelve native styles with a bounded page', (tester) async {
    const output = String.fromEnvironment('DATE_CARD_PREVIEW_DIR');
    const font = String.fromEnvironment('DATE_CARD_PREVIEW_FONT');
    if (font.isNotEmpty) {
      await tester.runAsync(() async {
        final loader = FontLoader('DatePreview')..addFont(File(font).readAsBytes().then(ByteData.sublistView));
        await loader.load();
      });
    }
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: font.isEmpty ? null : 'DatePreview'),
        home: Scaffold(
          backgroundColor: const Color(0xFFFFFEFA),
          body: RepaintBoundary(
            key: boundary,
            child: Container(
              color: const Color(0xFFFFFEFA),
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 12,
                runSpacing: 16,
                children: [
                  for (final style in collabDateCardStyles.entries)
                    SizedBox(
                      width: 173,
                      height: 176,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(style.value, style: const TextStyle(fontSize: 11, color: Color(0xFF8A8F9C))),
                          const SizedBox(height: 6),
                          Expanded(
                            child: CollabDateCardVisual(
                              card: CollabDateCard({'date': '2026-10-25T09:30', 'style': style.key}),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CollabDateCardVisual), findsNWidgets(12));
    expect(tester.takeException(), isNull);
    if (output.isNotEmpty) {
      await tester.runAsync(() async {
        final capture = await (boundary.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(
          pixelRatio: 2,
        );
        final data = await capture.toByteData(format: ui.ImageByteFormat.png);
        await Directory(output).create(recursive: true);
        await File('$output/date-card-gallery.png').writeAsBytes(data!.buffer.asUint8List());
        capture.dispose();
      });
    }
  });

  testWidgets('revocation then restoration cannot reactivate an old settings draft', (tester) async {
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: (_) {});
    await _settingsHost(tester, adapter.editorState);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await chooseDateCardStyle(tester, 'pill');
    adapter.editorState.editable = false;
    await tester.pump();
    adapter.editorState.editable = true;
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('date-card-apply'))).onPressed, isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(adapter.blocks.first.resource!.values['style'], 'calendar');
    await tester.pumpWidget(const SizedBox());
    adapter.dispose();
  });
}

/// 为每个测试创建新属性，防止共享可变夹具污染历史断言。
List<CollabEditorBlock> _blocks() => [
  CollabEditorBlock(
    id: 'date',
    blockType: 'date-card',
    text: '',
    resource: CollabResource.fromValues({
      'date': '2026-10-25T09:30',
      'style': 'calendar',
      'future': {'preserve': true},
    }),
  ),
  const CollabEditorBlock(id: 'p', blockType: 'paragraph', text: '正文'),
];

/// 在 [tester] 中展示借用 [state] 的设置入口；创建者在卸载后释放编辑器。
Future<void> _settingsHost(WidgetTester tester, EditorState state) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => await showCollabDateCardSettings(context, state, 'date'),
            child: const Text('设置'),
          ),
        ),
      ),
    ),
  );
}
