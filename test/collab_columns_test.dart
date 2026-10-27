import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_list_editing.dart';
import 'package:cses_document_collab/src/model/collab_columns.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 正式分栏的树、JSON、历史、权限、手机布局与公共菜单回归。
void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('keyboardHeightEventChannel'),
      MockStreamHandler.inline(onListen: (_, events) => events.success(0.0)),
    );
  });

  test('formal projection preserves children and edits only explicit width fields', () async {
    final published = <List<CollabEditorBlock>>[];
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: published.add);
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    final columns = state.document.root.children.first;
    expect(columns.type, 'columns');
    expect(columns.delta, isNull);
    expect(columns.children.first.children.first.delta!.toPlainText(), '第一列');
    expect(await editCollabColumns(state, 'columns', 'widen', columnId: 'left'), isTrue);
    expect(jsonDecode(published.last.first.resource!.propertyEdits!), {
      'columnCount': {'value': 2},
      'columnWidths': {
        'value': [35.0, 65.0],
      },
    });
    expect(published.last[2].parentId, 'left');
    state.undoManager.undo();
    await pumpEventQueue();
    expect(collabColumnWidths(columns), [30, 70]);
    state.undoManager.redo();
    await pumpEventQueue();
    expect(collabColumnWidths(columns), [35, 65]);
    final remote = adapter.blocks;
    await adapter.replaceFromRemote([remote.last, ...remote.take(remote.length - 1)]);
    final reordered = state.document.root.children.last;
    expect(reordered.attributes['cses_collab_block_id'], 'columns');
    state.undoManager.undo();
    await pumpEventQueue();
    expect(collabColumnWidths(reordered), [30, 70]);
  });

  test('add move delete and flatten preserve descendant identity with independent undo', () async {
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: (_) {});
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    expect(await editCollabColumns(state, 'columns', 'add', columnId: 'left'), isTrue);
    expect(state.document.root.children.first.children, hasLength(3));
    expect(await editCollabColumns(state, 'columns', 'right', columnId: 'left'), isTrue);
    expect(adapter.blocks.firstWhere((b) => b.id == 'left-text').parentId, 'left');
    expect(state.document.root.children.first.children[1].attributes['cses_collab_block_id'], 'left');
    expect(await editCollabColumns(state, 'columns', 'remove', columnId: 'left'), isTrue);
    expect(adapter.blocks.any((b) => b.id == 'left-text'), isFalse);
    state.undoManager.undo();
    await pumpEventQueue();
    expect(adapter.blocks.firstWhere((b) => b.id == 'left-text').text, '第一列');
    expect(await editCollabColumns(state, 'columns', 'flatten'), isTrue);
    expect(adapter.blocks.any((b) => b.blockType == 'columns' || b.blockType == 'column'), isFalse);
    expect(adapter.blocks.firstWhere((b) => b.id == 'left-text').parentId, isNull);
    state.undoManager.undo();
    await pumpEventQueue();
    expect(adapter.blocks.firstWhere((b) => b.id == 'left-text').parentId, 'left');
  });

  test('deleting one of two columns unwraps surviving content', () async {
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: (_) {});
    addTearDown(adapter.dispose);
    expect(await editCollabColumns(adapter.editorState, 'columns', 'remove', columnId: 'left'), isTrue);
    expect(adapter.blocks.map((b) => b.id), ['right-text', 'tail']);
    expect(adapter.blocks.first.parentId, isNull);
  });

  test('insert supports root and callout, rejects nested columns and enforces eight-column limit', () async {
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: (_) {});
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    expect(await insertCollabColumns(state, Selection.single(path: [0, 0, 0], startOffset: 0)), isNull);
    for (var i = 0; i < 6; i++) {
      expect(await editCollabColumns(state, 'columns', 'add'), isTrue);
    }
    expect(await editCollabColumns(state, 'columns', 'add'), isFalse);
    expect(await insertCollabColumns(state, Selection.single(path: [1], startOffset: 0)), isNotNull);
    expect(adapter.blocks.where((b) => b.blockType == 'columns'), hasLength(2));
  });

  test('column first paragraph backspace is protected, other paragraphs stay editable', () {
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: (_) {});
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    state.selection = Selection.single(path: [0, 0, 0], startOffset: 0);
    expect(isProtectedCalloutBoundary(state), isTrue);
    state.selection = Selection.single(path: [0, 0, 0], startOffset: 1);
    expect(isProtectedCalloutBoundary(state), isFalse);
  });

  testWidgets('word backspace uses the registered column guard before the standard command', (tester) async {
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: (_) {});
    final state = adapter.editorState;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DocumentEditorView(editorState: state)),
      ),
    );
    await tester.pumpAndSettle();
    final commands = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).commandShortcutEvents;
    final binding = deleteLeftWordCommand.keybindings.single;
    expect(commands.firstWhere((event) => event.keybindings.contains(binding)), same(collabBlockBackspaceCommand));
    final before = state.document.toJson();
    for (final path in [
      [0, 0, 0],
      [0, 1, 0],
      [1],
    ]) {
      state.selectionType = SelectionType.inline;
      state.selection = Selection.single(path: path, startOffset: 0);
      _dispatchWordBackspace(state, commands);
      await tester.pumpAndSettle();
      expect(state.document.toJson(), before);
    }
    final right = state.getNodeAtPath([0, 1, 0])!;
    await tester.tap(find.byWidgetPredicate((widget) => widget is AppFlowyRichText && identical(widget.node, right)));
    await tester.pumpAndSettle();
    state.selection = Selection.single(path: [0, 1, 0], startOffset: 0);
    await tester.pumpAndSettle();
    final modifier = binding.isAltPressed ? LogicalKeyboardKey.altLeft : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
    expect(state.document.toJson(), before);
    await tester.pumpWidget(const SizedBox());
    adapter.dispose();
  });

  testWidgets('word backspace preserves normal deletion and merging within one column', (tester) async {
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: (_) {});
    final state = adapter.editorState;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DocumentEditorView(editorState: state)),
      ),
    );
    await tester.pumpAndSettle();
    final first = state.getNodeAtPath([0, 0, 0])!;
    await state.apply(
      state.transaction..updateNode(first, {'delta': (Delta()..insert('alpha beta')).toJson()}),
      withUpdateSelection: false,
    );
    await tester.pumpAndSettle();
    state.selectionType = SelectionType.inline;
    state.selection = Selection.single(path: [0, 0, 0], startOffset: 10);
    _dispatchWordBackspace(state, [collabBlockBackspaceCommand, ...standardCommandShortcutEvents]);
    await tester.pumpAndSettle();
    expect(first.delta!.toPlainText(), 'alpha ');
    await state.apply(
      state.transaction..insertNode([0, 0, 1], paragraphNode(text: 'tail')),
      withUpdateSelection: false,
    );
    await tester.pumpAndSettle();
    state.selection = Selection.single(path: [0, 0, 1], startOffset: 0);
    _dispatchWordBackspace(state, [collabBlockBackspaceCommand, ...standardCommandShortcutEvents]);
    await tester.pumpAndSettle();
    expect(first.delta!.toPlainText(), 'alpha tail');
    expect(state.document.root.children.first.children.first.children, hasLength(1));
    expect(adapter.blocks.firstWhere((b) => b.id == 'right-text').text, '第二列');
    await tester.pumpWidget(const SizedBox());
    adapter.dispose();
  });

  test('word backspace outdents a column list before leaving it as a paragraph', () async {
    final blocks = _blocks();
    blocks[4] = const CollabEditorBlock(
      id: 'right-text',
      parentId: 'right',
      blockType: 'bulleted_list',
      text: '第二列',
      indent: 1,
    );
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: blocks, onLocalBlocksChanged: (_) {});
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    state.selection = Selection.single(path: [0, 1, 0], startOffset: 0);
    _dispatchWordBackspace(state, [collabBlockBackspaceCommand, ...standardCommandShortcutEvents]);
    await pumpEventQueue();
    expect(adapter.blocks.firstWhere((b) => b.id == 'right-text').indent, 0);
    state.selection = Selection.single(path: [0, 1, 0], startOffset: 0);
    _dispatchWordBackspace(state, [collabBlockBackspaceCommand, ...standardCommandShortcutEvents]);
    await pumpEventQueue();
    expect(state.getNodeAtPath([0, 1, 0])!.type, 'paragraph');
    expect(state.getNodeAtPath([0, 1, 0])!.delta!.toPlainText(), '第二列');
    expect(adapter.blocks.firstWhere((b) => b.id == 'left-text').text, '第一列');
  });

  test('legacy persisted columns preserve layout before and after text editing', () async {
    final snapshot =
        jsonDecode(File('rust/tests/fixtures/blockcraft-columns.json').readAsStringSync()) as Map<String, dynamic>;
    snapshot['children'] = [(snapshot['children'] as List).first];
    final fresh = BlockCraftJsonCodec.decode(snapshot);
    final saved = Document(root: _legacyColumns(fresh.root));
    final reopened = Document.fromJson(saved.toJson());
    final state = EditorState(document: reopened);
    addTearDown(fresh.dispose);
    addTearDown(saved.dispose);
    addTearDown(state.dispose);
    expect(reopened.root.children.first.type, 'snapshot-columns');
    expect(BlockCraftJsonCodec.encode(reopened), snapshot);
    final body = state.getNodeAtPath([0, 0, 0])!;
    await state.apply(state.transaction..insertText(body, body.delta!.length, '手机'), withUpdateSelection: false);
    final encoded = BlockCraftJsonCodec.encode(reopened);
    final group = (encoded['children'] as List).first as Map;
    expect(group['props']['columnCount'], 2);
    expect(group['props']['columnWidths'], [30, 70]);
    expect(group['children'][0]['props']['columnIndex'], 0);
    expect(group['props']['futureProp'], {'preserve': true});
    expect(group['meta'], {'audit': 'desktop'});
    expect(group['children'][0]['children'][0]['children'][0]['insert'], '第1列正文手机');
    final next = BlockCraftJsonCodec.decode(encoded);
    addTearDown(next.dispose);
    expect(BlockCraftJsonCodec.encode(next), encoded);
  });

  test('formal columns do not revive explicitly cleared properties from the original snapshot', () async {
    final snapshot =
        jsonDecode(File('rust/tests/fixtures/blockcraft-columns.json').readAsStringSync()) as Map<String, dynamic>;
    snapshot['children'] = [(snapshot['children'] as List).first];
    final doc = BlockCraftJsonCodec.decode(snapshot);
    final state = EditorState(document: doc);
    addTearDown(state.dispose);
    final group = doc.root.children.first;
    final column = group.children.first;
    await state.apply(
      state.transaction
        ..updateNode(group, {
          columnsPropertyAttribute('columnCount'): '{}',
          columnsPropertyAttribute('columnWidths'): '{}',
        })
        ..updateNode(column, {columnsPropertyAttribute('columnIndex'): '{}'}),
      withUpdateSelection: false,
    );
    final exported = BlockCraftJsonCodec.encode(doc);
    final block = (exported['children'] as List).first as Map;
    expect(block['props'].containsKey('columnCount'), isFalse);
    expect(block['props'].containsKey('columnWidths'), isFalse);
    expect(block['children'][0]['props'].containsKey('columnIndex'), isFalse);
    expect(block['props']['futureProp'], {'preserve': true});
  });

  test('column list conversion and enter preserve the column parent', () async {
    final blocks = _blocks();
    blocks[2] = const CollabEditorBlock(id: 'left-text', parentId: 'left', blockType: 'bulleted_list', text: '第一列');
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: blocks, onLocalBlocksChanged: (_) {});
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    state.selection = Selection.single(path: [0, 0, 0], startOffset: 3);
    expect(await changeCollabListType(state, 'todo_list'), isTrue);
    state.selection = Selection.single(path: [0, 0, 0], startOffset: 3);
    expect(await handleCollabListEnter(state), isTrue);
    expect(state.document.root.children.first.children.first.children, hasLength(2));
    expect(adapter.blocks.where((b) => b.parentId == 'left'), hasLength(2));
    expect(adapter.blocks.where((b) => b.blockType == 'todo_list'), hasLength(2));
  });

  test('readonly, descendant locks and stale identities reject structural mutations', () async {
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: (_) {});
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    final locks = CollabBlockLocks(editor: state, userId: 'me', canUnlock: (_) => false, commit: (_, _, _) async {});
    addTearDown(locks.dispose);
    locks.update([const CollabBlockLockState(blockId: 'left-text', sourceId: 'left-text', ownerId: 'other')]);
    expect(await editCollabColumns(state, 'columns', 'flatten'), isFalse);
    locks.update(const []);
    state.editable = false;
    expect(await editCollabColumns(state, 'columns', 'add'), isFalse);
    state.editable = true;
    expect(await editCollabColumns(state, 'missing', 'add'), isFalse);
  });

  test('JSON uses formal types and current widths; invalid widths fall back without mutation', () async {
    final fixture =
        jsonDecode(File('rust/tests/fixtures/blockcraft-columns.json').readAsStringSync()) as Map<String, dynamic>;
    fixture['children'] = [(fixture['children'] as List).first];
    final doc = BlockCraftJsonCodec.decode(fixture);
    final state = EditorState(document: doc);
    addTearDown(state.dispose);
    expect(doc.root.children.first.type, 'columns');
    expect(doc.root.children.first.children.first.type, 'column');
    expect(await editCollabColumns(state, 'columns', 'equal'), isTrue);
    expect(await editCollabColumns(state, 'columns', 'equal'), isFalse);
    final encoded = BlockCraftJsonCodec.encode(doc);
    expect((encoded['children'] as List).first['props']['columnWidths'], [50, 50]);
    expect((encoded['children'] as List).first['props']['futureProp'], {'preserve': true});
    expect((encoded['children'] as List).first['children'][0]['id'], 'column-0');
    final columns = doc.root.children.first;
    columns.updateAttributes({
      columnsPropertyAttribute('columnWidths'): jsonEncode({
        'value': [-1, 20],
      }),
    });
    final before = jsonEncode(columns.toJson());
    expect(collabColumnWidths(columns), [50, 50]);
    expect(jsonEncode(columns.toJson()), before);
    columns.updateAttributes({
      columnsPropertyAttribute('columnWidths'): jsonEncode({
        'value': [1e308, 1e308],
      }),
    });
    expect(collabColumnWidths(columns), [50, 50]);
  });

  testWidgets('common menu adds a column and rejects a stale open menu', (tester) async {
    const scale = 1.0;
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: (_) {});
    final state = adapter.editorState;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(body: DocumentEditorView(editorState: state)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('block-lock-menu-trigger-columns')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('columns-add-columns')));
    await tester.pumpAndSettle();
    expect(state.document.root.children.first.children, hasLength(3));
    await tester.tap(find.byKey(const ValueKey('block-lock-menu-trigger-columns')));
    await tester.pumpAndSettle();
    state.editable = false;
    state.editable = true;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('columns-flatten-columns')));
    await tester.pumpAndSettle();
    expect(state.document.root.children.first.type, 'columns');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    adapter.dispose();
  });

  for (final (width, scale) in [(320.0, 1.0), (390.0, 1.0), (320.0, 1.8), (900.0, 1.0)]) {
    testWidgets('phone layout, horizontal scrolling and preview retain real text at $width/$scale', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: (_) {});
      final state = adapter.editorState;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(body: DocumentEditorView(editorState: state)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final paragraphs = find.byWidgetPredicate(
        (w) => w is AppFlowyRichText && w.node.attributes['cses_collab_block_id'] == 'left-text',
      );
      expect(paragraphs, findsOneWidget);
      final horizontal = find.byWidgetPredicate(
        (w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      );
      expect(horizontal, findsOneWidget);
      final node = state.getNodeAtPath([0, 0, 0])!;
      await state.apply(state.transaction..insertText(node, node.delta!.length, '已编辑'), withUpdateSelection: false);
      await tester.pumpAndSettle();
      expect(adapter.blocks.firstWhere((b) => b.id == 'left-text').text, '第一列已编辑');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DocumentEditorView(editorState: state, preview: true)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('block-lock-menu-trigger-columns')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      adapter.dispose();
    });
  }
}

/// 构造两列与后置段落的正式前序投影，不依赖宿主业务或原生库。
List<CollabEditorBlock> _blocks() => [
  CollabEditorBlock(
    id: 'columns',
    blockType: 'columns',
    text: '',
    resource: CollabResource.fromValues({
      'columnCount': 2,
      'columnWidths': [30, 70],
    }),
  ),
  const CollabEditorBlock(id: 'left', parentId: 'columns', blockType: 'column', text: ''),
  const CollabEditorBlock(id: 'left-text', parentId: 'left', blockType: 'paragraph', text: '第一列'),
  const CollabEditorBlock(id: 'right', parentId: 'columns', blockType: 'column', text: ''),
  const CollabEditorBlock(id: 'right-text', parentId: 'right', blockType: 'paragraph', text: '第二列'),
  const CollabEditorBlock(id: 'tail', blockType: 'paragraph', text: '后续正文'),
];

/// 以真实按词退格绑定从[commands]中按顺序派发借用[state]，忽略的事件继续交给后续命令。
void _dispatchWordBackspace(EditorState state, List<CommandShortcutEvent> commands) {
  final binding = deleteLeftWordCommand.keybindings.single;
  for (final event in commands) {
    if (event.keybindings.contains(binding) && event.execute(state) == KeyEventResult.handled) return;
  }
}

/// 将借用[node]还原为旧版实际落盘的snapshot分栏树，正式正文属性保留，布局仅使用bc.p投影。
Node _legacyColumns(Node node) => Node(
  type: collabColumnsTypes.contains(node.type) ? 'snapshot-${node.type}' : node.type,
  id: node.id,
  attributes: {
    for (final entry in node.attributes.entries)
      if (!collabColumnsTypes.contains(node.type) || entry.key.startsWith('bc.')) entry.key: entry.value,
  },
  children: node.children.map(_legacyColumns).toList(),
);
