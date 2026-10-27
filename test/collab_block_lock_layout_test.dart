import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_lock_chrome.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_meeting_block.dart';
import 'package:cses_document_collab/src/model/collab_block_lock.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cses_document_collab/src/ui/modal/collab_block_lock_scope.dart';
import 'package:cses_document_collab/src/ui/modal/collab_card_frame.dart';
import 'package:cses_document_collab/src/ui/modal/collab_card_header.dart';

/// Verify corner badges remain visible through card/editor clipping at phone constraints.
void main() {
  const previewDirectory = String.fromEnvironment('LOCK_PREVIEW_DIR');
  const previewFont = String.fromEnvironment('LOCK_PREVIEW_FONT');
  setUpAll(() async {
    if (previewFont.isNotEmpty) {
      final font = FontLoader('LockPreviewFont')..addFont(File(previewFont).readAsBytes().then(ByteData.sublistView));
      await font.load();
      final icons = FontLoader('packages/lucide_icons_flutter/Lucide')
        ..addFont(rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'));
      await icons.load();
    }
  });
  for (final (width, scale) in [(320.0, 1.0), (280.0, 2.2), (390.0, 1.5)]) {
    testWidgets('locked meeting corner badge is not clipped at $width/$scale', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = AppFlowyBlockEditorAdapter(
        onLocalBlocksChanged: (_) {},
        initialBlocks: [
          CollabEditorBlock(
            id: 'meeting',
            blockType: 'meeting',
            text: '',
            resource: CollabResource.fromValues({'meetingId': 'm1', 'title': '会议标题'}),
          ),
        ],
      );
      final editor = adapter.editorState;
      final locks = CollabBlockLocks(editor: editor, userId: 'u1', canUnlock: (_) => false, commit: (_, _, _) async {});
      locks.update([
        const CollabBlockLockState(blockId: 'meeting', sourceId: 'meeting', ownerId: 'u1', containsLock: true),
      ]);
      editor.blockDecorator = (context, node, child) => node.type == 'meeting'
          ? RepaintBoundary(
              key: const ValueKey('lock-preview'),
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: decorateCollabBlockLock(context, editor, node, child),
              ),
            )
          : child;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: previewFont.isEmpty ? null : 'LockPreviewFont'),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: AppFlowyEditor(
                editorState: editor,
                editorStyle: const EditorStyle.mobile(),
                blockComponentBuilders: {
                  ...standardBlockComponentBuilderMap,
                  'meeting': CollabMeetingBlockComponentBuilder(),
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final card = tester.getRect(find.byKey(const ValueKey('meeting-card-surface-meeting')));
      final badge = tester.getRect(find.byKey(const ValueKey('block-lock-badge-meeting')));
      final menu = tester.getRect(find.byKey(const ValueKey('block-lock-menu-trigger-meeting')));
      expect(badge.top, closeTo(card.top - 5, 0.01));
      expect(badge.right, closeTo(card.right + 5, 0.01));
      expect(badge.center.dy, lessThan(menu.top));
      _expectUnclipped(tester, find.byKey(const ValueKey('block-lock-badge-meeting')));
      expect(find.byTooltip('内容已锁定'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (previewDirectory.isNotEmpty) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('lock-preview')));
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await Directory(previewDirectory).create(recursive: true);
          await File('$previewDirectory/meeting-lock-$width-$scale.png').writeAsBytes(data!.buffer.asUint8List());
        });
      }
      await tester.pumpWidget(const SizedBox());
      locks.dispose();
      adapter.dispose();
    });
    testWidgets('long card header keeps corner badge visible at $width/$scale', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: CollabBlockLockScope(
                  blockId: 'long',
                  showBadge: true,
                  child: CollabCardFrame(
                    surfaceKey: ValueKey('long-card'),
                    margin: EdgeInsets.symmetric(vertical: 6),
                    header: CollabCardHeader(
                      leading: Icon(Icons.event),
                      title: Text('这是一个非常非常长的标题需要省略显示，不能遮挡锁和更多操作'),
                      subtitle: 'https://example.test/a/very/long/resource',
                      more: Icon(Icons.more_horiz, key: ValueKey('more')),
                    ),
                    child: SizedBox(height: 40),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final card = tester.getRect(find.byKey(const ValueKey('long-card')));
      final badge = tester.getRect(find.byKey(const ValueKey('block-lock-badge-long')));
      final menu = tester.getRect(find.byKey(const ValueKey('more')));
      expect(badge.top, closeTo(card.top - 5, 0.01));
      expect(badge.right, closeTo(card.right + 5, 0.01));
      expect(badge.center.dy, lessThan(menu.top));
      _expectUnclipped(tester, find.byKey(const ValueKey('block-lock-badge-long')));
      expect(tester.takeException(), isNull);
    });
  }
}

/// Check every ancestor's paint clip contains the entire badge found by [finder]
/// in [tester], so matching layout coordinates alone cannot hide a clipped icon.
void _expectUnclipped(WidgetTester tester, Finder finder) {
  final badge = tester.getRect(finder);
  RenderObject child = tester.renderObject(finder);
  while (child.parent != null) {
    final parent = child.parent!;
    final clip = parent.describeApproximatePaintClip(child);
    if (clip != null) {
      final visible = MatrixUtils.transformRect(parent.getTransformTo(null), clip);
      expect(visible.inflate(0.01).contains(badge.topLeft), isTrue, reason: '$parent clips badge top/left');
      expect(visible.inflate(0.01).contains(badge.bottomRight), isTrue, reason: '$parent clips badge bottom/right');
    }
    child = parent;
  }
}
