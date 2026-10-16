import 'package:cses_document_collab/src/editor/collab_embed_block.dart';
import 'package:cses_document_collab/src/model/collab_image.dart';
import 'dart:async';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_meeting_block.dart';
import 'package:cses_document_collab/src/editor/collab_resource_block.dart';
import 'package:cses_document_collab/src/editor/collab_task_card_block.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:metalink/metalink.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../test/support/fake_link_web_platform.dart';

/// 在Android真机/模拟器运行真实手机选择服务与触摸手势；不接入账号、网络或原生协同文档。
/// 从Demo宿主使用flutter drive，driver为本包test_driver/integration_test.dart，target为此文件，device指定Android。
/// WebView、音频与业务回调使用本地替身；编辑器、节点、选择服务及拖动手势均使用实际实现。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    expect(
      Platform.isAndroid,
      isTrue,
      reason: '此回归必须在Android设备运行，不能用macOS的mobile样式代替',
    );
  });

  for (final kind in ['meeting', 'task', ...collabResourceTypes]) {
    testWidgets('$kind background tap preserves action hit testing', (
      tester,
    ) async {
      var opened = 0;
      final owner = Object();
      CollabRuntime.acquire(
        owner,
        CollabHostServices(
          onMeetingCardTap: (_, _, _) {
            opened++;
          },
          onMentionTap: (_) {
            opened++;
          },
        ),
      );
      final oldWeb = WebViewPlatform.instance;
      final oldPlayer = VideoPlayerPlatform.instance;
      WebViewPlatform.instance = FakeLinkWebPlatform();
      VideoPlayerPlatform.instance = _LocalPlayer();
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          _card(kind),
          _paragraph('tail', 'abcdefghijklmnopqrstuvwxyz'),
        ],
        onLocalBlocksChanged: (_) {},
      );
      try {
        await _mount(tester, adapter);
        final editor = adapter.editorState;
        expect(_type('MobileSelectionServiceWidget'), findsOneWidget);
        expect(editor.document.first!.delta, isNull);
        await _selectCard(tester, editor);
        if (kind == 'meeting' || kind == 'task') {
          final openKey = kind == 'meeting'
              ? 'meeting-open-card'
              : 'task-card-open-card';
          await tester.tap(find.byKey(ValueKey(openKey)));
          await tester.pumpAndSettle();
          expect(opened, 1);
          await _selectCard(tester, editor);
          if (kind == 'task' || kind == 'meeting') {
            await tester.tap(
              find.byKey(
                ValueKey(
                  kind == 'task' ? 'task-card-more-card' : 'block-more-card',
                ),
              ),
            );
            await tester.pumpAndSettle();
          }
          await tester.tap(
            find.byKey(
              ValueKey(
                kind == 'meeting'
                    ? 'meeting-delete-card'
                    : 'task-card-delete-card',
              ),
            ),
          );
        } else {
          await tester.tap(
            find.byKey(
              ValueKey(
                const {'audio', 'attachment'}.contains(kind)
                    ? 'block-more-card'
                    : 'resource-more-card',
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('resource-edit-card')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('resource-field-url')),
            findsOneWidget,
          );
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          await _selectCard(tester, editor);
          await tester.tap(
            find.byKey(
              ValueKey(
                const {'audio', 'attachment'}.contains(kind)
                    ? 'block-more-card'
                    : 'resource-more-card',
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('resource-delete-card')));
        }
        await tester.pumpAndSettle();
        expect(adapter.blocks.any((b) => b.id == 'card'), isFalse);
        expect(adapter.blocks.last.text, 'abcdefghijklmnopqrstuvwxyz');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 100));
        adapter.dispose();
        CollabRuntime.release(owner);
        WebViewPlatform.instance = oldWeb;
        VideoPlayerPlatform.instance = oldPlayer;
      }
    });
  }

  for (final kind in ['image', 'video']) {
    testWidgets('$kind real body tap does not cover media controls', (
      tester,
    ) async {
      final old = VideoPlayerPlatform.instance;
      final player = _LocalPlayer();
      VideoPlayerPlatform.instance = player;
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          CollabEditorBlock(
            id: 'media',
            blockType: kind,
            text: kind == 'image'
                ? 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='
                : 'https://example.test/video.mp4',
            image: kind == 'image' ? const CollabImage() : null,
          ),
          _paragraph('tail', 'media adjacent paragraph'),
        ],
        onLocalBlocksChanged: (_) {},
      );
      try {
        await _mount(tester, adapter);
        final node = adapter.editorState.document.first!;
        final selectable = node.selectable!;
        final rect = selectable.getBlockRect();
        final point = selectable.localToGlobal(
          rect.topLeft + const Offset(12, 30),
        );
        await tester.tapAt(point);
        await _layout(tester);
        expect(adapter.editorState.selection!.isCollapsed, isTrue);
        expect(_type('MobileCollapsedHandle'), findsNothing);
        expect(find.byType(IconButton), findsNWidgets(kind == 'video' ? 2 : 1));
        if (kind == 'video') {
          await tester.tap(
            find.byKey(const ValueKey('collab-video-block-play')),
          );
          await tester.pumpAndSettle();
          expect(player.played, contains(0));
          await tester.tap(
            find.byKey(const ValueKey('collab-video-block-play')),
          );
        } else {
          await tester.tap(find.byKey(const ValueKey('block-more-media')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('collab-image-edit')));
          await tester.pumpAndSettle();
          expect(find.byType(ModalBarrier), findsWidgets);
        }
        expect(adapter.blocks.last.text, 'media adjacent paragraph');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        adapter.dispose();
        VideoPlayerPlatform.instance = old;
      }
    });
  }

  testWidgets(
    'dragging a text range across a card keeps text endpoint handles',
    (tester) async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          _paragraph('before', 'abcdefghij klmnopqrst'),
          _card('meeting'),
          _paragraph('after', 'uvwxyz second paragraph'),
        ],
        onLocalBlocksChanged: (_) {},
      );
      try {
        await _mount(tester, adapter);
        final editor = adapter.editorState;
        await tester.tapAt(_textPoint(editor, 0, 3));
        await _layout(tester);
        final cursor = tester.getRect(_handleGesture()).center;
        final cursorEnd = _textPoint(editor, 2, 9) + const Offset(0, 16);
        await tester.timedDragFrom(
          cursor,
          cursorEnd - cursor,
          const Duration(milliseconds: 600),
        );
        await _layout(tester);
        expect(editor.selection!.isCollapsed, isTrue);
        expect(editor.selection!.start.path, [2]);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.longPressAt(_textPoint(editor, 0, 3));
        await _layout(tester);
        expect(editor.selection!.isCollapsed, isFalse);
        final right = tester.getRect(_handleGesture(last: true)).center;
        final end = _textPoint(editor, 2, 9) + const Offset(0, 16);
        await tester.timedDragFrom(
          right,
          end - right,
          const Duration(milliseconds: 600),
        );
        await _layout(tester);
        expect(editor.selection!.normalized.start.path, [0]);
        expect(editor.selection!.normalized.end.path, [2]);
        expect(_type('MobileSelectionHandle'), findsNWidgets(2));
        expect(adapter.blocks.map((b) => b.id), ['before', 'card', 'after']);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        adapter.dispose();
      }
    },
  );

  testWidgets(
    'text caret, cursor dragging and range handle dragging remain functional',
    (tester) async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          _paragraph('text', 'abcdefghij klmnopqrst uvwxyz'),
          _paragraph('tail', 'second paragraph'),
        ],
        onLocalBlocksChanged: (_) {},
      );
      try {
        await _mount(tester, adapter);
        final editor = adapter.editorState;
        await tester.tapAt(_textPoint(editor, 0, 3));
        await _layout(tester);
        expect(editor.selection!.isCollapsed, isTrue);
        expect(editor.selection!.start.path, [0]);
        expect(_type('MobileCollapsedHandle'), findsOneWidget);
        final before = editor.selection!.start.offset;
        final cursor = tester.getRect(_handleGesture()).center;
        final target = _textPoint(editor, 0, 8);
        await tester.timedDragFrom(
          cursor,
          Offset(target.dx - cursor.dx, 0),
          const Duration(milliseconds: 400),
        );
        await _layout(tester);
        expect(editor.selection!.isCollapsed, isTrue);
        expect(editor.selection!.start.offset, greaterThan(before));
        await tester.pump(const Duration(milliseconds: 600));
        await tester.longPressAt(_textPoint(editor, 0, 14));
        await _layout(tester);
        expect(editor.selection!.isCollapsed, isFalse);
        expect(_type('MobileSelectionHandle'), findsNWidgets(2));
        final previousEnd = editor.selection!.normalized.end.offset;
        final rightHandle = tester.getRect(_handleGesture(last: true)).center;
        final end = _textPoint(editor, 0, 25);
        await tester.timedDragFrom(
          rightHandle,
          Offset(end.dx - rightHandle.dx, 0),
          const Duration(milliseconds: 400),
        );
        await _layout(tester);
        expect(
          editor.selection!.normalized.end.offset,
          greaterThan(previousEnd),
        );
        expect(adapter.blocks.first.text, 'abcdefghij klmnopqrst uvwxyz');
        expect(adapter.blocks.last.text, 'second paragraph');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        adapter.dispose();
      }
    },
  );
}

/// 查找实际运行时类型[type]，避免跨包导入AppFlowy内部手机服务实现。
Finder _type(String type) =>
    find.byWidgetPredicate((widget) => widget.runtimeType.toString() == type);

/// 命中实际手柄的手势热区；[last]为true选择右侧范围手柄，默认选择单光标。
/// DragHandle外层Stack可覆盖整个选词矩形，不能以其中心代替实际拖动热区。
Finder _handleGesture({bool last = false}) => find
    .descendant(
      of: last ? _type('DragHandle').last : _type('DragHandle'),
      matching: find.byType(GestureDetector),
    )
    .first;

/// 真实点击卡片标题产生Android折叠选区，紧接着验证未出现整卡文字手柄。
/// [tester]驱动触摸，[editor]为借用编辑器；短帧推进确保没有等待自动隐藏计时器掩盖问题。
Future<void> _selectCard(WidgetTester tester, EditorState editor) async {
  await tester.pump(const Duration(milliseconds: 600));
  await tester.tap(find.text('pointer title').first);
  await _layout(tester);
  expect(editor.selection!.isCollapsed, isTrue);
  expect(editor.selection!.start.path, [0]);
  expect(editor.selectionType, SelectionType.inline);
  expect(_type('MobileCollapsedHandle'), findsNothing);
  expect(_type('MobileSelectionHandle'), findsNothing);
}

/// 为[tester]推进选区的布局后通知，不等待Android三秒手柄超时。
Future<void> _layout(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 60));
  await tester.pump(const Duration(milliseconds: 60));
}

/// 从借用[editor]中第[row]段的[offset]字符获取实际布局后的全局触摸点。
Offset _textPoint(EditorState editor, int row, int offset) {
  final selectable = editor.getNodeAtPath([row])!.selectable!;
  final rect = selectable.getCursorRectInPosition(
    Position(path: [row], offset: offset),
    shiftWithBaseOffset: true,
  )!;
  return selectable.localToGlobal(rect.center, shiftWithBaseOffset: true);
}

/// 在[tester]中挂载借用[adapter]的真实编辑器；关闭键盘服务以保持设备视口和触摸坐标稳定。
/// 手机选择服务和光标/范围手柄完整启用，资源加载仅使用本地替身。
Future<void> _mount(
  WidgetTester tester,
  AppFlowyBlockEditorAdapter adapter,
) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        AppFlowyEditorLocalizations.delegate,
      ],
      home: Scaffold(
        body: AppFlowyEditor(
          editorState: adapter.editorState,
          disableKeyboardService: true,
          editorStyle: const EditorStyle.mobile(padding: EdgeInsets.all(16)),
          blockComponentBuilders: {
            ...standardBlockComponentBuilderMap,
            'image': CollabEmbedBlockComponentBuilder(
              kind: CollabEmbedKind.image,
            ),
            'video': CollabEmbedBlockComponentBuilder(
              kind: CollabEmbedKind.video,
            ),
            'meeting': CollabMeetingBlockComponentBuilder(),
            'task': CollabTaskCardBlockComponentBuilder(),
            for (final kind in collabResourceTypes)
              kind: CollabResourceBlockComponentBuilder(loadPreview: _metadata),
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 使用合成数据构造[kind]卡片；不会读取用户文档或业务状态。
CollabEditorBlock _card(String kind) => CollabEditorBlock(
  id: 'card',
  blockType: kind,
  text: switch (kind) {
    'meeting' || 'task' => '',
    'juejin-embed' => 'https://juejin.cn/post/123',
    'figma-embed' => 'https://www.figma.com/design/fixture/Test',
    _ => 'https://example.test/resource',
  },
  resource: CollabResource.fromValues({
    if (kind == 'meeting') 'meetingId': 'm1',
    if (kind == 'task') 'taskId': 't1',
    'title': 'pointer title',
    'name': 'pointer title',
    'number': '123456',
  }),
);

/// 构造稳定身份[id]、正文[text]的合成段落。
CollabEditorBlock _paragraph(String id, String text) =>
    CollabEditorBlock(id: id, blockType: 'paragraph', text: text);

/// 为[url]返回本地HTML元数据，不联网。
Future<ExtractionResult<LinkMetadata>> _metadata(String url) =>
    MetaLinkParser().parseHtml(
      '<html><head><title>local preview</title></head></html>',
      documentUrl: Uri.parse(url),
    );

/// 只为音频布局提供本地初始化结果，不创建播放器或发出网络请求。
class _LocalPlayer extends VideoPlayerPlatform {
  /// 本地播放调用记录，不访问真实播放器。
  final played = <int>[];
  final _streams = <int, StreamController<VideoEvent>>{};
  int _next = 0;

  /// 初始化替身，不持有平台资源。
  @override
  Future<void> init() async {}

  /// 为借用创建参数[options]分配本地事件流。
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _next++;
    final stream = StreamController<VideoEvent>();
    _streams[id] = stream;
    stream.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 10),
        size: const Size(10, 10),
      ),
    );
    return id;
  }

  /// 返回[playerId]的本地事件流。
  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _streams[playerId]!.stream;

  /// 关闭本替身拥有的[playerId]事件流，重复关闭无操作。
  @override
  Future<void> dispose(int playerId) async {
    await _streams.remove(playerId)?.close();
  }

  /// 接受[playerId]的循环[looping]设置，不改变真实设备。
  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  /// 接受[playerId]的音量[volume]设置。
  @override
  Future<void> setVolume(int playerId, double volume) async {}

  /// 接受[playerId]的速率[speed]设置。
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  /// 暂停本地[playerId]替身。
  @override
  Future<void> pause(int playerId) async {}

  /// 播放本地[playerId]替身。
  @override
  Future<void> play(int playerId) async {
    played.add(playerId);
  }

  /// 接受[playerId]的进度[position]设置。
  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  /// 为[options]返回纯布局替身，不创建纹理或原生视图。
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand();

  /// 返回[playerId]的固定本地进度。
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
}
