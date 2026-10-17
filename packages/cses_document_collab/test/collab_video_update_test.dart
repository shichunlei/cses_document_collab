import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_video_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// 隔离真实播放器，验证同一 Node 的源更新及退出时的所有权，不访问网络。
void main() {
  for (final pending in [false, true]) {
    testWidgets(
      'same node video source replacement releases controllers (pending=$pending)',
      (tester) async {
        final platform = _MemoryVideoPlatform(pending: pending);
        final original = VideoPlayerPlatform.instance;
        VideoPlayerPlatform.instance = platform;
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: [_video('a')],
          onLocalBlocksChanged: (_) {},
        );
        final state = adapter.editorState;
        final node = state.document.first!;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          adapter.dispose();
          await platform.close();
          VideoPlayerPlatform.instance = original;
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AppFlowyEditor(
                editorState: state,
                disableKeyboardService: true,
                blockComponentBuilders: {
                  ...standardBlockComponentBuilderMap,
                  csesVideoBlockType: CollabVideoBlockComponentBuilder(),
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(platform.sources, ['https://example.test/a.mp4']);
        expect(find.byType(IconButton), findsNWidgets(pending ? 1 : 2));
        expect(
          find.byKey(const ValueKey('collab-video-block-play')),
          pending ? findsNothing : findsOneWidget,
        );
        if (!pending) {
          for (final label in ['播放视频', '暂停视频']) {
            await tester.tap(
              find.byKey(const ValueKey('collab-video-block-play')),
            );
            await tester.pumpAndSettle();
            final controller = tester
                .widget<VideoPlayer>(find.byType(VideoPlayer))
                .controller;
            expect(controller.value.isPlaying, label == '播放视频');
          }
        }
        state.editable = false;
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('block-more-video')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('block-insert-below-video')),
          findsNothing,
        );
        expect(find.text('在外部应用打开'), findsOneWidget);
        expect(find.widgetWithText(ListTile, '播放视频'), findsNothing);
        expect(find.widgetWithText(ListTile, '暂停视频'), findsNothing);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        state.editable = true;
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<BlockComponentStatefulWidget>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is BlockComponentStatefulWidget &&
                      widget.node.type == csesVideoBlockType,
                ),
              )
              .node,
          same(node),
        );
        for (final source in ['b', 'a']) {
          await adapter.replaceFromRemote([_video(source)]);
          await tester.pumpAndSettle();
          // 播放器平台的流取消在真实异步区域完成，单纯推进帧时间不会完成它。
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pumpAndSettle();
          expect(adapter.blocks.single.text, _video(source).text);
          expect(state.document.first, same(node));
          expect(platform.disposed.length, source == 'b' ? 1 : 2);
          expect(platform.sources.last, 'https://example.test/$source.mp4');
          if (!pending) {
            expect(
              tester
                  .widget<VideoPlayer>(find.byType(VideoPlayer))
                  .controller
                  .dataSource,
              'https://example.test/$source.mp4',
            );
          }
        }
        expect(platform.sources, hasLength(3));
        expect(platform.disposed, [0, 1]);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(platform.disposed, [0, 1, 2]);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final mode in ['edit', 'preview', 'zero', 'error', 'stale', 'narrow']) {
    testWidgets('video timeline supports $mode safely', (tester) async {
      final platform = _MemoryVideoPlatform(
        pending: false,
        duration: mode == 'zero' ? Duration.zero : const Duration(seconds: 90),
      );
      final original = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = platform;
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [_video('progress')],
        onLocalBlocksChanged: changes.add,
      );
      adapter.editorState.editable = mode != 'preview';
      if (mode == 'narrow') {
        await tester.binding.setSurfaceSize(const Size(280, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
      }
      addTearDown(() async {
        if (platform.seekGate != null && !platform.seekGate!.isCompleted) {
          platform.seekGate!.complete();
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        adapter.dispose();
        await platform.close();
        VideoPlayerPlatform.instance = original;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(
                textScaler: TextScaler.linear(mode == 'narrow' ? 2 : 1),
              ),
              child: SizedBox(
                width: 320,
                child: AppFlowyEditor(
                  editorState: adapter.editorState,
                  editable: adapter.editorState.editable,
                  disableKeyboardService: true,
                  editorStyle: const EditorStyle.mobile(
                    padding: EdgeInsets.all(16),
                  ),
                  blockComponentBuilders: {
                    ...standardBlockComponentBuilderMap,
                    csesVideoBlockType: CollabVideoBlockComponentBuilder(),
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final progress = find.byKey(const ValueKey('collab-video-progress'));
      expect(progress, findsOneWidget);
      final picture = tester.getRect(find.byType(VideoPlayer));
      final track = tester.getRect(progress);
      final elapsed = tester.getRect(
        find.byKey(const ValueKey('collab-video-position')),
      );
      expect(track.top, greaterThan(picture.center.dy));
      expect(elapsed.bottom, lessThanOrEqualTo(picture.bottom));
      expect(picture.width / picture.height, closeTo(1, 0.01));
      var slider = tester.widget<Slider>(progress);
      if (mode == 'zero') {
        expect(slider.onChanged, isNull);
        expect(slider.value, 0);
        expect(find.text('00:00'), findsNWidgets(2));
      } else {
        var controller = tester
            .widget<VideoPlayer>(find.byType(VideoPlayer))
            .controller;
        controller.value = controller.value.copyWith(
          position: const Duration(seconds: 20),
        );
        await tester.pump();
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('collab-video-position')))
              .data,
          '00:20',
        );
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('collab-video-duration')))
              .data,
          '01:30',
        );
        expect(tester.widget<Slider>(progress).value, 20000);
        if (mode == 'stale') {
          platform.seekGate = Completer<void>();
          slider = tester.widget<Slider>(progress);
          slider.onChanged!(60000);
          slider.onChangeEnd!(60000);
          await tester.pump();
          expect(platform.seeks.single, (0, const Duration(seconds: 60)));
          await adapter.replaceFromRemote([_video('replacement')]);
          await tester.pumpAndSettle();
          expect(platform.disposed, isEmpty, reason: '关闭必须等待仍在使用控制器的跳转');
          expect(progress, findsNothing);
          platform.seekGate!.complete();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pumpAndSettle();
          controller = tester
              .widget<VideoPlayer>(find.byType(VideoPlayer))
              .controller;
          expect(controller.dataSource, contains('replacement'));
          expect(tester.widget<Slider>(progress).value, 0);
          expect(platform.disposed, [0]);
        } else {
          platform.failSeek = mode == 'error';
          final rect = tester.getRect(progress);
          await tester.dragFrom(
            Offset(rect.left + rect.width * 0.25, rect.center.dy),
            Offset(rect.width * 0.5, 0),
          );
          await tester.pumpAndSettle();
          expect(platform.seeks, hasLength(1), reason: '拖动仅在松手时跳转一次');
          expect(platform.seeks.single.$2.inSeconds, inInclusiveRange(45, 90));
          if (mode == 'error') {
            expect(find.text('视频跳转失败，请重试'), findsOneWidget);
            expect(tester.widget<Slider>(progress).value, 20000);
          } else {
            expect(
              tester.widget<Slider>(progress).value,
              platform.seeks.single.$2.inMilliseconds,
            );
          }
          expect(tester.widget<Slider>(progress).onChanged, isNotNull);
        }
      }
      expect(changes, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}

/// 为 [source] 创建相同身份的视频块；仅返回投影，不创建网络资源。
CollabEditorBlock _video(String source) => CollabEditorBlock(
  id: 'video',
  blockType: csesVideoBlockType,
  text: 'https://example.test/$source.mp4',
);

/// 通过官方平台端口记录创建/释放，不使用真实解码器；测试持有流并负责 close。
class _MemoryVideoPlatform extends VideoPlayerPlatform {
  /// [pending] 为 true 时不发送初始化完成事件，用于验证加载期间换源和退出。
  _MemoryVideoPlatform({
    required this.pending,
    this.duration = const Duration(seconds: 1),
  });

  /// 夹具媒体时长；零模拟未知/不可跳转的时长。
  final Duration duration;

  /// 当前每个播放器的位置；模拟原生进度查询和跳转结果。
  final positions = <int, Duration>{};

  /// 实际原生跳转请求，记录控制器身份与毫秒位置。
  final seeks = <(int, Duration)>[];

  /// true模拟原生跳转失败，位置保持不变。
  bool failSeek = false;

  /// 由测试持有并完成的跳转阻塞，验证换源/关闭等待。
  Completer<void>? seekGate;

  /// 是否保持播放器初始化等待；不影响平台资源创建和释放完成。
  final bool pending;
  final List<String> sources = [];
  final List<int> disposed = [];
  final Map<int, StreamController<VideoEvent>> _events = {};

  /// 初始化内存平台，无外部资源，立即完成。
  @override
  Future<void> init() => Future.value();

  /// 按 [options] 的网络源分配整数身份及流；非 pending 时发送一次元数据。
  /// Future 立即返回身份，不执行媒体请求，流由测试平台持有。
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = sources.length;
    sources.add(options.dataSource.uri!);
    // Ownership transfers to _events; dispose/close await each retained sink.
    // ignore: close_sinks
    final events = StreamController<VideoEvent>();
    _events[id] = events;
    if (!pending) {
      events.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: duration,
          size: const Size(100, 100),
        ),
      );
    }
    return id;
  }

  /// 返回 [playerId] 的事件流；仅接受本平台创建的身份，不转移流所有权。
  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  /// 记录 [playerId] 释放并关闭其流；Future 在流关闭后完成。
  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    await _events.remove(playerId)?.close();
  }

  /// Accepts playback for borrowed [playerId] without a native decoder.
  @override
  Future<void> play(int playerId) async {}

  /// Applies [speed] for borrowed [playerId] without native playback.
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  /// 返回借用[playerId]最近一次成功跳转的位置，默认从零开始。
  @override
  Future<Duration> getPosition(int playerId) async =>
      positions[playerId] ?? Duration.zero;

  /// 记录[playerId]到[position]的跳转；可阻塞或失败，由测试控制完成时机。
  @override
  Future<void> seekTo(int playerId, Duration position) async {
    seeks.add((playerId, position));
    if (seekGate != null) await seekGate!.future;
    if (failSeek) throw StateError('fixture seek failure');
    positions[playerId] = position;
  }

  /// 接收 [playerId] 的 [looping] 设置；内存平台不执行播放，立即完成。
  @override
  Future<void> setLooping(int playerId, bool looping) => Future.value();

  /// 接收 [playerId] 的 [volume]（0～1）；内存平台静音，立即完成。
  @override
  Future<void> setVolume(int playerId, double volume) => Future.value();

  /// 接收 [playerId] 暂停请求，不创建定时器，立即完成。
  @override
  Future<void> pause(int playerId) => Future.value();

  /// 为 [options] 对应的播放器提供静态占位，不创建 Texture 或平台视图。
  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox();

  /// 测试退出时释放尚未关闭的所有流，Future 在全部关闭后完成。
  Future<void> close() async {
    await Future.wait(_events.values.map((events) => events.close()));
    _events.clear();
  }
}
