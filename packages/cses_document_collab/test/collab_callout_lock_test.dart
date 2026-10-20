import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_callout_block.dart';
import 'package:cses_document_collab/src/model/collab_block_lock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cses_document_collab/src/ui/modal/collab_emoji_picker.dart';

/// Exercise prefix hit targets and open picker invalidation with real block guards.
void main() {
  late AppFlowyBlockEditorAdapter adapter;
  late CollabBlockLocks locks;

  /// Install [locked] authority, using [source] for inherited locks and [template]
  /// for template-origin locks; projection changes do not write body or history.
  void update({bool locked = true, String source = 'callout', bool template = false}) => locks.update([
    CollabBlockLockState(
      blockId: 'callout',
      sourceId: locked ? source : null,
      ownerId: locked ? 'u1' : null,
      template: template,
      containsLock: locked,
    ),
  ]);

  setUp(() {
    adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [
        CollabEditorBlock(id: 'callout', blockType: 'callout', text: '', calloutPrefix: '💡'),
        CollabEditorBlock(id: 'body', parentId: 'callout', blockType: 'paragraph', text: '定稿内容'),
      ],
      onLocalBlocksChanged: (_) {},
    );
    locks = CollabBlockLocks(
      editor: adapter.editorState,
      userId: 'u1',
      canUnlock: (_) => false,
      commit: (_, _, _) async {},
    );
    update(locked: false);
  });
  tearDown(() {
    locks.dispose();
    adapter.dispose();
  });

  /// Mount the borrowed editor on [tester]'s mobile surface; the caller unmounts
  /// before teardown releases the lock projection and editor.
  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppFlowyEditor(
            editorState: adapter.editorState,
            disableKeyboardService: true,
            editorStyle: const EditorStyle.mobile(),
            blockComponentBuilders: {
              ...standardBlockComponentBuilderMap,
              'callout': CollabCalloutBlockComponentBuilder(),
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final kind in ['user', 'inherited', 'template']) {
    testWidgets('$kind lock disables prefix and refuses direct picker/appearance entry', (tester) async {
      update(source: kind == 'inherited' ? 'ancestor' : 'callout', template: kind == 'template');
      await mount(tester);
      final prefix = find.byKey(const ValueKey('collab-callout-prefix'));
      expect(tester.widget<InkWell>(prefix).onTap, isNull);
      final before = adapter.editorState.document.toJson();
      final node = adapter.editorState.getNodeAtPath([0])!;
      await showCollabCalloutEmojiPicker(tester.element(prefix), adapter.editorState, node);
      await updateCollabCalloutAppearance(adapter.editorState, 'callout', csesCalloutPrefixAttribute, '😎');
      await tester.pumpAndSettle();
      expect(find.byType(CollabEmojiPicker), findsNothing);
      expect(adapter.editorState.document.toJson(), before);
      expect(adapter.editorState.undoManager.undoStack, isEmpty);
      expect(find.text('💡'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('remote lock then unlock disables an open picker and rejects its old callback', (tester) async {
    await mount(tester);
    final prefix = find.byKey(const ValueKey('collab-callout-prefix'));
    await tester.tap(prefix);
    await tester.pumpAndSettle();
    final stalePicker = tester.widget<CollabEmojiPicker>(find.byType(CollabEmojiPicker));
    expect(stalePicker.enabled, isTrue);
    update();
    await tester.pumpAndSettle();
    expect(tester.widget<CollabEmojiPicker>(find.byType(CollabEmojiPicker)).enabled, isFalse);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('callout-emoji-clear'))).onPressed, isNull);
    update(locked: false);
    await tester.pumpAndSettle();
    expect(tester.widget<CollabEmojiPicker>(find.byType(CollabEmojiPicker)).enabled, isFalse);
    await stalePicker.onSelected('😎');
    expect(adapter.blocks.first.calloutPrefix, '💡');
    expect(adapter.editorState.undoManager.undoStack, isEmpty);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(prefix);
    await tester.pumpAndSettle();
    final fresh = tester.widget<CollabEmojiPicker>(find.byType(CollabEmojiPicker));
    expect(fresh.enabled, isTrue);
    await fresh.onSelected('😎');
    await tester.pumpAndSettle();
    expect(adapter.blocks.first.calloutPrefix, '😎');
    adapter.editorState.undoManager.undo();
    await tester.pumpAndSettle();
    expect(adapter.blocks.first.calloutPrefix, '💡');
    expect(adapter.editorState.undoManager.undoStack.isEmpty, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('locking disables a mounted prefix and unlocking restores new entry', (tester) async {
    await mount(tester);
    final prefix = find.byKey(const ValueKey('collab-callout-prefix'));
    expect(tester.widget<InkWell>(prefix).onTap, isNotNull);
    update();
    await tester.pumpAndSettle();
    expect(tester.widget<InkWell>(prefix).onTap, isNull);
    update(locked: false);
    await tester.pumpAndSettle();
    expect(tester.widget<InkWell>(prefix).onTap, isNotNull);
    await tester.tap(prefix);
    await tester.pumpAndSettle();
    expect(tester.widget<CollabEmojiPicker>(find.byType(CollabEmojiPicker)).enabled, isTrue);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(adapter.editorState.undoManager.undoStack, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
