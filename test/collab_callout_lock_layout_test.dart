import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_lock_chrome.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_callout_block.dart';
import 'package:cses_document_collab/src/editor/collab_image_block.dart';
import 'package:cses_document_collab/src/model/collab_block_lock.dart';
import 'package:cses_document_collab/src/model/collab_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verify the actual callout surface anchors the badge independently of its children.
void main() {
  for (final (width, scale) in [(320.0, 1.0), (280.0, 2.2), (390.0, 1.5)]) {
    testWidgets('callout corner lock is visible at $width/$scale', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'callout',
            blockType: 'callout',
            text: '',
            calloutPrefix: '💡',
            blockBackgroundColor: '#E3F2FD',
          ),
          CollabEditorBlock(
            id: 'text',
            parentId: 'callout',
            blockType: 'bullet',
            text: '高亮块内的长段落，锁标应跟随整个卡片，不占用正文和更多按钮的位置。',
          ),
          CollabEditorBlock(
            id: 'image',
            parentId: 'callout',
            blockType: 'image',
            text: 'blob:callout-lock-fixture',
            image: CollabImage(aspectRatio: 1.5),
          ),
          CollabEditorBlock(id: 'nested', parentId: 'callout', blockType: 'callout', text: ''),
          CollabEditorBlock(id: 'nested-text', parentId: 'nested', blockType: 'paragraph', text: '嵌套高亮'),
        ],
        onLocalBlocksChanged: (_) {},
      );
      final editor = adapter.editorState;
      final locks = CollabBlockLocks(editor: editor, userId: 'u1', canUnlock: (_) => false, commit: (_, _, _) async {});
      addTearDown(() {
        locks.dispose();
        adapter.dispose();
      });
      editor.blockDecorator = (context, node, child) => decorateCollabBlockLock(context, editor, node, child);
      final snapshot = editor.document.toJson();
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: AppFlowyEditor(
                editorState: editor,
                disableKeyboardService: true,
                editorStyle: const EditorStyle.mobile(),
                blockComponentBuilders: {
                  ...standardBlockComponentBuilderMap,
                  'callout': CollabCalloutBlockComponentBuilder(),
                  'image': CollabImageBlockComponentBuilder(),
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final badge = find.byKey(const ValueKey('block-lock-badge-callout'));
      expect(badge, findsNothing);
      locks.update([
        const CollabBlockLockState(blockId: 'callout', sourceId: 'callout', ownerId: 'u1', containsLock: true),
        for (final id in ['text', 'image', 'nested', 'nested-text'])
          CollabBlockLockState(blockId: id, sourceId: 'callout', ownerId: 'u1'),
      ]);
      await tester.pumpAndSettle();
      final surface = find
          .ancestor(of: find.byKey(const ValueKey('block-more-callout')), matching: find.byType(Container))
          .first;
      final card = tester.getRect(surface);
      final marker = tester.getRect(badge);
      expect(marker.top, closeTo(card.top - 5, 0.01));
      expect(marker.right, closeTo(card.right + 5, 0.01));
      _expectUnclipped(tester, badge);
      expect(find.byTooltip('内容已锁定'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('block-lock-menu-trigger-callout')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('block-lock-callout')), findsOneWidget);
      expect(find.text('删除高亮块'), findsNothing);
      await tester.tap(find.byTooltip('关闭').last);
      await tester.pumpAndSettle();
      locks.update([
        const CollabBlockLockState(blockId: 'callout', sourceId: 'callout', ownerId: 'u1', template: true),
      ]);
      await tester.pumpAndSettle();
      expect(badge, findsNothing);
      locks.update([]);
      await tester.pumpAndSettle();
      expect(badge, findsNothing);
      expect(editor.document.toJson(), snapshot);
      expect(editor.undoManager.undoStack, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

/// Confirm all ancestor paint clips contain the badge [finder] mounted by [tester].
void _expectUnclipped(WidgetTester tester, Finder finder) {
  final badge = tester.getRect(finder);
  RenderObject child = tester.renderObject(finder);
  while (child.parent != null) {
    final parent = child.parent!;
    final clip = parent.describeApproximatePaintClip(child);
    if (clip != null) {
      final visible = MatrixUtils.transformRect(parent.getTransformTo(null), clip);
      expect(visible.inflate(0.01).contains(badge.topLeft), isTrue, reason: '$parent clips lock');
      expect(visible.inflate(0.01).contains(badge.bottomRight), isTrue, reason: '$parent clips lock');
    }
    child = parent;
  }
}
