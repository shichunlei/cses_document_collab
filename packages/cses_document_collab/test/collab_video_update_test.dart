import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_embed_block.dart';
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
                  csesVideoBlockType: CollabEmbedBlockComponentBuilder(
                    kind: CollabEmbedKind.video,
                  ),
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(platform.sources, ['https://example.test/a.mp4']);
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
  _MemoryVideoPlatform({required this.pending});

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
    final events = StreamController<VideoEvent>();
    _events[id] = events;
    if (!pending) {
      events.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 1),
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
