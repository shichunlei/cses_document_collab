import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_lock_chrome.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_image_block.dart';
import 'package:cses_document_collab/src/model/collab_block_lock.dart';
import 'package:cses_document_collab/src/model/collab_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Check resized images anchor locks to the image instead of full-width caption rows.
void main() {
  for (final (width, scale, alignment) in [(320.0, 1.0, 'left'), (280.0, 2.2, 'center'), (390.0, 1.5, 'right')]) {
    testWidgets('image lock follows $alignment image at $width/$scale', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          CollabEditorBlock(
            id: 'image',
            blockType: 'image',
            text: 'blob:lock-layout',
            alignment: alignment,
            image: const CollabImage(
              widthRatio: 60,
              aspectRatio: 1.5,
              captions: [CollabImageCaption(id: 'caption', text: '图1')],
            ),
          ),
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
      locks.update([const CollabBlockLockState(blockId: 'image', sourceId: 'image', ownerId: 'u1')]);
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
                  'image': CollabImageBlockComponentBuilder(),
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final surface = tester.getRect(find.byKey(const ValueKey('collab-image-box')));
      final badge = find.byKey(const ValueKey('block-lock-badge-image'));
      final rect = tester.getRect(badge);
      expect(rect.top, closeTo(surface.top - 5, 0.01));
      expect(rect.right, closeTo(surface.right + 5, 0.01));
      RenderObject child = tester.renderObject(badge);
      while (child.parent != null) {
        final parent = child.parent!;
        final clip = parent.describeApproximatePaintClip(child);
        if (clip != null) {
          final visible = MatrixUtils.transformRect(parent.getTransformTo(null), clip).inflate(0.01);
          expect(visible.contains(rect.topLeft), isTrue, reason: '$parent clips lock');
          expect(visible.contains(rect.bottomRight), isTrue, reason: '$parent clips lock');
        }
        child = parent;
      }
      expect(find.byTooltip('内容已锁定'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('block-lock-menu-trigger-image')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('block-lock-image')), findsOneWidget);
      await tester.tap(find.byTooltip('关闭').last);
      await tester.pumpAndSettle();
      locks.update([const CollabBlockLockState(blockId: 'image', sourceId: 'ancestor', ownerId: 'u1')]);
      await tester.pumpAndSettle();
      expect(badge, findsNothing);
      expect(editor.document.toJson(), snapshot);
      expect(editor.undoManager.undoStack, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
