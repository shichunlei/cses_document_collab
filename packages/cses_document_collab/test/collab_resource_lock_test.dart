import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_attachment_block.dart';
import 'package:cses_document_collab/src/editor/collab_block_lock_chrome.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_bookmark_block.dart';
import 'package:cses_document_collab/src/editor/collab_figma_embed_block.dart';
import 'package:cses_document_collab/src/editor/collab_juejin_embed_block.dart';
import 'package:cses_document_collab/src/editor/collab_web_embed_block.dart';
import 'package:cses_document_collab/src/model/collab_block_lock.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metalink/metalink.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'support/fake_link_web_platform.dart';

/// Creates a real [kind] resource and authority projection, initially [locked].
/// Test teardown releases locks before the borrowed editor; commits update only
/// the lock projection, preserving document content and its undo history.
({AppFlowyBlockEditorAdapter adapter, CollabBlockLocks locks, List<bool> commits, void Function(bool) update}) _fixture(
  String kind, {
  bool locked = false,
}) {
  final adapter = AppFlowyBlockEditorAdapter(
    initialBlocks: [
      CollabEditorBlock(
        id: 'resource',
        blockType: kind,
        text: switch (kind) {
          'figma-embed' => 'https://www.figma.com/design/test',
          'juejin-embed' => 'https://juejin.cn/post/123',
          _ => 'https://example.test/file.pdf',
        },
        resource: CollabResource.fromValues({'name': '资源名称'}),
      ),
    ],
    onLocalBlocksChanged: (_) {},
  );
  final commits = <bool>[];
  late CollabBlockLocks locks;

  /// Installs the effective lock [value] without editing source attributes.
  void update(bool value) => locks.update([
    CollabBlockLockState(
      blockId: 'resource',
      sourceId: value ? 'resource' : null,
      ownerId: value ? 'u1' : null,
      containsLock: value,
    ),
  ]);

  locks = CollabBlockLocks(
    editor: adapter.editorState,
    userId: 'u1',
    canUnlock: (_) => false,
    commit: (_, value, _) async {
      commits.add(value);
      update(value);
    },
  );
  update(locked);
  addTearDown(() {
    locks.dispose();
    adapter.dispose();
  });
  return (adapter: adapter, locks: locks, commits: commits, update: update);
}

/// Mounts borrowed [adapter] through production decorators on a narrow screen.
/// [tester] owns the surface; fake platform views avoid network/native access.
Future<void> _mount(WidgetTester tester, AppFlowyBlockEditorAdapter adapter) async {
  await tester.binding.setSurfaceSize(const Size(320, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final editor = adapter.editorState;
  editor.blockDecorator = (context, node, child) => decorateCollabBlockLock(context, editor, node, child);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
        child: Scaffold(
          body: AppFlowyEditor(
            editorState: editor,
            disableKeyboardService: true,
            editorStyle: const EditorStyle.mobile(),
            blockComponentBuilders: {
              ...standardBlockComponentBuilderMap,
              'attachment': CollabAttachmentBlockComponentBuilder(),
              'bookmark': CollabBookmarkBlockComponentBuilder(
                loadPreview: (url) =>
                    MetaLinkParser().parseHtml('<head><title>预览</title></head>', documentUrl: Uri.parse(url)),
              ),
              'embed': CollabWebEmbedBlockComponentBuilder(),
              'figma-embed': CollabFigmaEmbedBlockComponentBuilder(),
              'juejin-embed': CollabJuejinEmbedBlockComponentBuilder(),
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Verifies the badge found by [finder] in [tester] survives all ancestor clips.
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

/// Exercises real resource renderers, lock menus and stale authority projections.
void main() {
  setUp(() => WebViewPlatform.instance = FakeLinkWebPlatform());
  for (final kind in ['attachment', 'bookmark', 'embed', 'figma-embed', 'juejin-embed']) {
    testWidgets('$kind displays an unclipped corner lock', (tester) async {
      final fixture = _fixture(kind, locked: true);
      await _mount(tester, fixture.adapter);
      final badge = find.byKey(const ValueKey('block-lock-badge-resource'));
      expect(badge, findsOneWidget);
      final surface = find
          .byWidgetPredicate((widget) => widget is Container && widget.clipBehavior == Clip.antiAlias)
          .first;
      final card = tester.getRect(surface);
      final marker = tester.getRect(badge);
      expect(marker.top, closeTo(card.top - 5, 0.01));
      expect(marker.right, closeTo(card.right + 5, 0.01));
      _expectUnclipped(tester, badge);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('$kind menu toggles lock and preserves content/history', (tester) async {
      final fixture = _fixture(kind);
      final editor = fixture.adapter.editorState;
      final snapshot = editor.document.toJson();
      await _mount(tester, fixture.adapter);
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      expect(find.text('锁定内容块'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('block-lock-resource')));
      await tester.pumpAndSettle();
      expect(fixture.commits, [true]);
      expect(find.byKey(const ValueKey('block-lock-badge-resource')), findsOneWidget);
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('resource-edit-resource')), findsNothing);
      expect(find.byKey(const ValueKey('resource-delete-resource')), findsNothing);
      expect(find.byKey(const ValueKey('link-view-card')), findsNothing);
      if (kind != 'attachment') expect(find.byKey(const ValueKey('link-copy')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('block-lock-resource')));
      await tester.pumpAndSettle();
      expect(fixture.commits, [true, false]);
      expect(find.byKey(const ValueKey('block-lock-badge-resource')), findsNothing);
      expect(editor.document.toJson(), snapshot);
      expect(editor.undoManager.undoStack, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('old web menu cannot mutate after remote lock then unlock', (tester) async {
    final fixture = _fixture('embed');
    await _mount(tester, fixture.adapter);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    fixture.update(true);
    fixture.update(false);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('block-lock-resource'))).onChanged, isNull);
    await tester.tap(find.byKey(const ValueKey('link-view-card')));
    await tester.pumpAndSettle();
    expect(fixture.adapter.blocks.single.blockType, 'embed');
    expect(fixture.adapter.editorState.undoManager.undoStack, isEmpty);
    expect(fixture.commits, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  for (final (scenario, source, owner, template) in [
    ('other owner', 'resource', 'u2', false),
    ('template', 'resource', 'u1', true),
    ('inherited', 'ancestor', 'u1', false),
  ]) {
    testWidgets('web lock menu respects $scenario authority', (tester) async {
      final fixture = _fixture('embed');
      fixture.locks.update([
        CollabBlockLockState(
          blockId: 'resource',
          sourceId: source,
          ownerId: owner,
          template: template,
          containsLock: true,
        ),
      ]);
      await _mount(tester, fixture.adapter);
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('block-lock-resource'))).onChanged, isNull);
      expect(find.byKey(const ValueKey('resource-edit-resource')), findsNothing);
      expect(find.byKey(const ValueKey('link-copy')), findsOneWidget);
      expect(find.text('定位上级锁定块'), scenario == 'inherited' ? findsOneWidget : findsNothing);
      await tester.pumpWidget(const SizedBox());
      expect(fixture.commits, isEmpty);
    });
  }

  testWidgets('web lock choice rejects a changed source before dismissal', (tester) async {
    final fixture = _fixture('embed');
    await _mount(tester, fixture.adapter);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('block-lock-resource')));
    await fixture.adapter.replaceFromRemote(const [
      CollabEditorBlock(
        id: 'resource',
        blockType: 'embed',
        text: 'https://example.test/new',
        resource: CollabResource(),
      ),
    ]);
    await tester.pumpAndSettle();
    expect(fixture.commits, isEmpty);
    expect(fixture.adapter.blocks.single.text, 'https://example.test/new');
    expect(find.text('内容已更新，请重新选择'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
