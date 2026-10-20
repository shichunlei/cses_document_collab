import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/model/collab_block_lock.dart';
import 'package:cses_document_collab/src/model/collab_text_range.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercise real AppFlowy transactions, history and the production block menu.
void main() {
  late AppFlowyBlockEditorAdapter adapter;
  late CollabBlockLocks locks;
  var extraGrant = false;
  var commits = 0;
  final copied = <String>[];

  /// Install authority-derived lock states, retaining an editable sibling.
  /// [locked] controls protection; [owner] identifies the locking user and
  /// [template] enables the template-specific unlock permission.
  void update({bool locked = true, String owner = 'alice', bool template = false}) {
    locks.update([
      CollabBlockLockState(
        blockId: 'a',
        sourceId: locked ? 'a' : null,
        ownerId: locked ? owner : null,
        template: template,
        containsLock: locked,
      ),
      const CollabBlockLockState(blockId: 'b'),
    ]);
  }

  setUp(() {
    extraGrant = false;
    commits = 0;
    copied.clear();
    adapter = AppFlowyBlockEditorAdapter(
      onLocalBlocksChanged: (_) {},
      initialBlocks: const [
        CollabEditorBlock(id: 'a', blockType: 'paragraph', text: '定稿'),
        CollabEditorBlock(id: 'b', blockType: 'paragraph', text: '可编辑'),
      ],
    );
    locks = CollabBlockLocks(
      editor: adapter.editorState,
      userId: 'alice',
      canUnlock: (_) => extraGrant,
      commit: (id, locked, expected) async {
        commits++;
        update(locked: locked);
      },
    );
    update(locked: false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
  });
  tearDown(() {
    locks.dispose();
    adapter.dispose();
  });

  test('locked text, format, delete and mixed transactions are atomic; sibling remains editable', () async {
    final editor = adapter.editorState;
    final a = editor.getNodeAtPath([0])!;
    final b = editor.getNodeAtPath([1])!;
    update();
    for (final transaction in [
      editor.transaction..insertText(a, 0, 'X'),
      editor.transaction..formatText(a, 0, 1, {'bold': true}),
      editor.transaction..deleteNode(a),
      editor.transaction
        ..insertText(b, 0, 'Y')
        ..insertText(a, 0, 'X'),
    ]) {
      await editor.apply(transaction);
      expect(a.delta!.toPlainText(), '定稿');
      expect(b.delta!.toPlainText(), '可编辑');
      expect(editor.undoManager.undoStack.isEmpty, isTrue);
    }
    await editor.apply(editor.transaction..insertText(b, 0, 'Y'));
    expect(b.delta!.toPlainText(), 'Y可编辑');
    expect(editor.canInputAt(Selection.single(path: [0], startOffset: 0)), isFalse);
    expect(editor.canInputAt(Selection.single(path: [1], startOffset: 0)), isTrue);
  });

  test('blocked undo and redo retain their original entries until unlock', () async {
    final editor = adapter.editorState;
    final a = editor.getNodeAtPath([0])!;
    await editor.apply(editor.transaction..insertText(a, 0, 'X'));
    final undo = editor.undoManager.undoStack.last;
    update();
    editor.undoManager.undo();
    expect(identical(editor.undoManager.undoStack.last, undo), isTrue);
    expect(a.delta!.toPlainText(), 'X定稿');
    update(locked: false);
    editor.undoManager.undo();
    expect(a.delta!.toPlainText(), '定稿');
    final redo = editor.undoManager.redoStack.last;
    update();
    editor.undoManager.redo();
    expect(identical(editor.undoManager.redoStack.last, redo), isTrue);
    update(locked: false);
    editor.undoManager.redo();
    expect(a.delta!.toPlainText(), 'X定稿');
  });

  test('insert before locked sibling is safe even when later paths shift', () async {
    final editor = adapter.editorState;
    update();
    await editor.apply(editor.transaction..insertNode([0], paragraphNode(text: '新段')));
    expect(editor.getNodeAtPath([1])!.delta!.toPlainText(), '定稿');
    final transaction = editor.transaction..insertNode([0], paragraphNode(text: '不能留下'));
    transaction.add(UpdateTextOperation([2], Delta()..insert('X'), Delta()..delete(1)), transform: false);
    expect(locks.allows(transaction), isFalse);
    await editor.apply(transaction);
    expect(editor.document.root.children.length, 3);
  });

  test('old modal and text ranges stay invalid after lock then unlock', () async {
    final editor = adapter.editorState;
    editor.selection = Selection.single(path: [0], startOffset: 0, endOffset: 1);
    final range = CollabTextRange.capture(editor)!;
    final lease = locks.beginLease();
    update();
    update(locked: false);
    expect(locks.writable('a'), isFalse);
    expect(locks.writable('b'), isTrue);
    expect(range.resolve(editor), isNull);
    await editor.apply(editor.transaction..insertText(editor.getNodeAtPath([0])!, 0, '旧草稿'));
    expect(adapter.blocks.first.text, '定稿');
    locks.endLease(lease);
    expect(locks.writable('a'), isTrue);
  });

  test('owner, another user, template and inherited permissions match desktop', () {
    update();
    expect(locks.canToggle('a'), isTrue);
    update(owner: 'bob');
    expect(locks.canToggle('a'), isFalse);
    extraGrant = true;
    expect(locks.canToggle('a'), isTrue);
    extraGrant = false;
    update(template: true);
    expect(locks.canToggle('a'), isFalse);
    extraGrant = true;
    expect(locks.canToggle('a'), isTrue);
    locks.update([const CollabBlockLockState(blockId: 'a', sourceId: 'parent', ownerId: 'alice')]);
    expect(locks.canToggle('a'), isFalse);
    adapter.editorState.editable = false;
    expect(locks.canToggle('a'), isFalse);
  });

  for (final kind in ['paragraph', 'code']) {
    for (final locked in [false, true]) {
      testWidgets('$kind menu lock=$locked toggles without copy content', (tester) async {
        await adapter.replaceFromRemote([
          CollabEditorBlock(id: 'a', blockType: kind, text: '定稿'),
          const CollabEditorBlock(id: 'b', blockType: 'paragraph', text: '可编辑'),
        ]);
        update(locked: locked);
        final editor = adapter.editorState;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CollabBlockMoreButton(
                editor: editor,
                node: editor.getNodeAtPath([0])!,
                actions: [(label: '删除内容', key: null, run: () async {})],
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();
        expect(find.text('锁定内容块'), findsOneWidget);
        expect(find.text('删除内容'), locked ? findsNothing : findsOneWidget);
        expect(find.text('复制内容'), findsNothing);
        await tester.tap(
          find.descendant(of: find.byKey(const ValueKey('block-lock-a')), matching: find.byType(Switch)),
        );
        await tester.pumpAndSettle();
        expect(commits, 1);
        expect(locks.state('a').locked, !locked);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  for (final kind in ['callout', 'mermaid']) {
    testWidgets('copy locked $kind writes only the system clipboard', (tester) async {
      final isDiagram = kind == 'mermaid';
      final source = isDiagram ? 'flowchart LR\nA-->B' : '定稿\n高亮正文';
      await adapter.replaceFromRemote([
        CollabEditorBlock(id: 'a', blockType: kind, text: ''),
        if (isDiagram)
          CollabEditorBlock(id: 'source', parentId: 'a', blockType: 'mermaid-textarea', text: source)
        else ...[
          const CollabEditorBlock(id: 'first', parentId: 'a', blockType: 'paragraph', text: '定稿'),
          const CollabEditorBlock(id: 'second', parentId: 'a', blockType: 'paragraph', text: '高亮正文'),
        ],
        const CollabEditorBlock(id: 'b', blockType: 'paragraph', text: '可编辑'),
      ]);
      update();
      final editor = adapter.editorState;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CollabBlockMoreButton(editor: editor, node: editor.getNodeAtPath([0])!, protectSubtree: true),
          ),
        ),
      );
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      expect(find.text(isDiagram ? '复制内容' : '复制代码'), findsNothing);
      await tester.tap(find.text(isDiagram ? '复制代码' : '复制内容'));
      await tester.pumpAndSettle();
      expect(copied, [source]);
      expect(commits, 0);
      expect(editor.undoManager.undoStack.isEmpty, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
