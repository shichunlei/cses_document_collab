import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_list_editing.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_text_box.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 正式文本框的字段历史、正文、锁及手机设置回归。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = Platform.environment['TEXT_BOX_PREVIEW_FONT'];
    if (font != null) {
      final loader = FontLoader('TextBoxPreview')
        ..addFont(File(font).readAsBytes().then((bytes) => ByteData.sublistView(bytes)));
      await loader.load();
      final icons = FontLoader('packages/lucide_icons_flutter/Lucide')
        ..addFont(rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'));
      await icons.load();
    }
  });
  test('formal JSON retains edited text, metadata and unknown properties', () async {
    final snapshot =
        jsonDecode(File('rust/tests/fixtures/blockcraft-text-box.json').readAsStringSync()) as Map<String, dynamic>;
    snapshot['children'] = [(snapshot['children'] as List).first];
    final doc = BlockCraftJsonCodec.decode(snapshot);
    final state = EditorState(document: doc);
    addTearDown(state.dispose);
    final box = doc.root.children.first;
    expect(box.type, 'text-box');
    expect(BlockCraftJsonCodec.encode(doc), snapshot);
    expect(await updateCollabTextBox(state, 'text-box', {'width': 320}), isTrue);
    final child = box.children.first;
    await state.apply(state.transaction..insertText(child, child.delta!.length, '手机'), withUpdateSelection: false);
    final output = (BlockCraftJsonCodec.encode(doc)['children'] as List).first as Map;
    expect(output['props']['width'], 320);
    expect(output['props']['futureProp'], {'preserve': true});
    expect(output['meta'], {'audit': 'desktop'});
    expect(output['children'][0]['id'], 'box-body');
    expect(child.delta!.toPlainText(), '文本框正文手机');
  });
  testWidgets('persisted legacy snapshot text-box remains visible and exports its original geometry', (tester) async {
    final legacy = Document(
      root: Node(
        type: 'page',
        children: [
          Node(
            type: 'snapshot-text-box',
            attributes: {
              'bc.flavour': 'text-box',
              'bc.nodeType': 'block',
              'bc.p:width': {'v': 300},
              'bc.p:height': {'v': 160},
            },
            children: [paragraphNode(text: '旧文本框')],
          ),
        ],
      ),
    );
    final state = EditorState(document: legacy);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DocumentEditorView(
              editorState: state,
              configuration: EditorViewConfiguration(blockBuilders: blockCraftSnapshotBuilders),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byWidgetPredicate((w) => w is AppFlowyRichText && w.node.delta?.toPlainText() == '旧文本框'),
        findsOneWidget,
      );
      final output = (BlockCraftJsonCodec.encode(legacy)['children'] as List).first as Map;
      expect(output['props'], {'width': 300, 'height': 160});
    } finally {
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    }
  });
  test('field undo follows stable identity after remote reorder', () async {
    final adapter = _adapter();
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    expect(await updateCollabTextBox(state, 'text-box', {'width': 360}), isTrue);
    expect(await updateCollabTextBox(state, 'text-box', {'width': 360}), isFalse);
    expect(state.undoManager.undoStack.isNonEmpty, isTrue);
    final remote = adapter.blocks;
    await adapter.replaceFromRemote([remote.last, ...remote.take(remote.length - 1)]);
    state.undoManager.undo();
    await pumpEventQueue();
    expect(readCollabTextBox(findCollabActionNode(state, 'text-box')!.attributes).values['width'], 300);
    state.undoManager.redo();
    await pumpEventQueue();
    expect(readCollabTextBox(findCollabActionNode(state, 'text-box')!.attributes).values['width'], 360);
  });
  test('insert and delete undo preserve children and list Enter stays in frame', () async {
    final adapter = _adapter();
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    state.selection = Selection.single(path: [0, 0], startOffset: 0);
    expect(isProtectedCalloutBoundary(state), isTrue);
    await applyEditorBlockStyle(state, 'bulleted_list');
    expect(await changeCollabListType(state, 'todo_list'), isTrue);
    state.selection = Selection.single(path: [0, 0], startOffset: 5);
    expect(await handleCollabListEnter(state), isTrue);
    expect(state.document.root.children.first.children, hasLength(2));
    final landing = await insertCollabTextBox(state, Selection.single(path: [1], startOffset: 0));
    expect(landing!.start.path, [2, 0]);
    final box = state.getNodeAtPath([2])!;
    final id = CollabBlockLocks.idOf(box);
    final child = box.children.first.id;
    expect(await deleteCollabTextBox(state, id), isTrue);
    state.undoManager.undo();
    await pumpEventQueue();
    expect(findCollabActionNode(state, id)!.children.first.id, child);
    expect(await insertCollabTextBox(state, Selection.single(path: [0, 0], startOffset: 0)), isNull);
  });
  test('readonly, descendant locks, invalid geometry and missing identities reject writes', () async {
    final adapter = _adapter();
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    final locks = CollabBlockLocks(editor: state, userId: 'me', canUnlock: (_) => false, commit: (_, _, _) async {});
    addTearDown(locks.dispose);
    locks.update([const CollabBlockLockState(blockId: 'box-body', sourceId: 'box-body', ownerId: 'other')]);
    expect(await deleteCollabTextBox(state, 'text-box'), isFalse);
    locks.update([]);
    state.editable = false;
    expect(await updateCollabTextBox(state, 'text-box', {'width': 400}), isFalse);
    state.editable = true;
    await expectLater(updateCollabTextBox(state, 'text-box', {'width': double.nan}), throwsArgumentError);
    expect(await updateCollabTextBox(state, 'missing', {'width': 400}), isFalse);
  });
  testWidgets('native input connection accepts composed Chinese and emoji inside the frame', (tester) async {
    final adapter = _adapter();
    final state = adapter.editorState;
    final registered = !tester.testTextInput.isRegistered;
    if (registered) tester.testTextInput.register();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DocumentEditorView(editorState: state)),
        ),
      );
      await tester.pumpAndSettle();
      final selected = state.updateSelectionWithReason(
        Selection.single(path: [0, 0], startOffset: 5),
        reason: SelectionUpdateReason.uiEvent,
      );
      await tester.pump();
      await selected;
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.testTextInput.hasAnyClients, isTrue);
      final editing = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
      final start = editing.selection.start;
      final value = editing.copyWith(
        text: editing.text.replaceRange(start, editing.selection.end, '中文🙂'),
        selection: TextSelection.collapsed(offset: start + 4),
        composing: TextRange.empty,
      );
      tester.testTextInput.editingState = value.toJSON();
      tester.testTextInput.updateEditingValue(value);
      await tester.pump(const Duration(milliseconds: 200));
      expect(adapter.blocks.firstWhere((b) => b.id == 'box-body').text, '文本框正文中文🙂');
      expect(adapter.blocks.firstWhere((b) => b.id == 'tail').text, '后续正文');
    } finally {
      await tester.pumpWidget(const SizedBox());
      adapter.dispose();
      if (registered) tester.testTextInput.unregister();
    }
  });
  test('explicitly clearing a field does not revive original JSON props', () async {
    final snapshot =
        jsonDecode(File('rust/tests/fixtures/blockcraft-text-box.json').readAsStringSync()) as Map<String, dynamic>;
    snapshot['children'] = [(snapshot['children'] as List).first];
    final doc = BlockCraftJsonCodec.decode(snapshot);
    final state = EditorState(document: doc);
    addTearDown(state.dispose);
    expect(await updateCollabTextBox(state, 'text-box', {'width': null}), isTrue);
    final exported = (BlockCraftJsonCodec.encode(doc)['children'] as List).first as Map;
    expect((exported['props'] as Map).containsKey('width'), isFalse);
    state.undoManager.undo();
    await pumpEventQueue();
    expect(readCollabTextBox(doc.root.children.first.attributes).values['width'], 300);
    state.selection = Selection.single(path: [0, 0], startOffset: 0);
    await applyEditorBlockStyle(state, 'code');
    expect(state.getNodeAtPath([0, 0])!.type, 'paragraph');
  });
  for (final (width, scale) in [(320.0, 1.0), (390.0, 1.0), (320.0, 1.8), (700.0, 1.0)]) {
    testWidgets('settings cancel, apply, stale permission and preview at $width/$scale', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final adapter = _adapter();
      final state = adapter.editorState;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: Platform.environment['TEXT_BOX_PREVIEW_FONT'] == null ? null : 'TextBoxPreview'),
          builder: (context, child) => RepaintBoundary(
            key: const ValueKey('text-box-capture'),
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
          ),
          home: Scaffold(
            body: DocumentEditorView(
              editorState: state,
              configuration: EditorViewConfiguration(
                style: (context, style) => Platform.environment['TEXT_BOX_PREVIEW_FONT'] == null
                    ? style
                    : style.copyWith(
                        textStyleConfiguration: style.textStyleConfiguration.copyWith(
                          text: style.textStyleConfiguration.text.copyWith(fontFamily: 'TextBoxPreview'),
                        ),
                      ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(const ValueKey('text-box-frame-text-box'))).width, lessThanOrEqualTo(width));
      if (width == 390) await _capture(tester, 'text-box-content.png');
      await _openSettings(tester);
      if (width == 390) await _capture(tester, 'text-box-settings.png');
      await tester.enterText(find.byKey(const ValueKey('text-box-width')), '400');
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(readCollabTextBox(state.document.root.children.first.attributes).values['width'], 300);
      await _openSettings(tester);
      await tester.enterText(find.byKey(const ValueKey('text-box-width')), '400');
      await tester.tap(find.byKey(const ValueKey('text-box-apply')));
      await tester.pumpAndSettle();
      expect(readCollabTextBox(state.document.root.children.first.attributes).values['width'], 400);
      expect(state.undoManager.undoStack.isNonEmpty, isTrue);
      await _openSettings(tester);
      final remote = adapter.blocks;
      await adapter.replaceFromRemote([
        CollabEditorBlock(
          id: 'text-box',
          blockType: 'text-box',
          text: '',
          resource: CollabResource.fromValues({'width': 450, 'height': 160}),
        ),
        ...remote.skip(1),
      ]);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('text-box-apply'))).onPressed, isNull);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();

      await _openSettings(tester);
      state.editable = false;
      state.editable = true;
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('text-box-apply'))).onPressed, isNull);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DocumentEditorView(editorState: state, preview: true)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('block-lock-menu-trigger-text-box')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      adapter.dispose();
    });
  }
}

/// 为借用[tester]打开公共更多菜单及文本框设置，等待两个弹窗完成转换。
Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('block-lock-menu-trigger-text-box')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('text-box-settings-text-box')));
  await tester.pumpAndSettle();
}

/// 创建不访问原生或宿主资源的内存投影。
AppFlowyBlockEditorAdapter _adapter() => AppFlowyBlockEditorAdapter(
  initialBlocks: [
    CollabEditorBlock(
      id: 'text-box',
      blockType: 'text-box',
      text: '',
      resource: CollabResource.fromValues({'width': 300, 'height': 160}),
    ),
    const CollabEditorBlock(id: 'box-body', parentId: 'text-box', blockType: 'paragraph', text: '文本框正文'),
    const CollabEditorBlock(id: 'tail', blockType: 'paragraph', text: '后续正文'),
  ],
  onLocalBlocksChanged: (_) {},
);

/// 将借用[tester]中的真实Flutter画面保存为[name]；未配置输出目录时不执行截图。
Future<void> _capture(WidgetTester tester, String name) async {
  final output = Platform.environment['TEXT_BOX_PREVIEW_DIR'];
  if (output == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('text-box-capture')));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$output/$name').writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
