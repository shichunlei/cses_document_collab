import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_lock_chrome.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/model/collab_block_lock.dart';
import 'package:cses_document_collab/src/editor/collab_video_block.dart';
import 'package:cses_document_collab/src/editor/collab_callout_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// 隔离真实播放器，验证视频交互的焦点屏蔽、同一Node源更新及退出所有权，不访问网络。
void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(0.0),
          ),
        );
  });

  for (final (width, scale) in [(320.0, 1.0), (280.0, 2.2), (390.0, 1.5)]) {
    for (final mode in ['ready', 'loading', 'failed']) {
      testWidgets('video corner lock remains visible at $width/$scale $mode', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        final platform = _MemoryVideoPlatform(pending: mode != 'ready');
        final original = VideoPlayerPlatform.instance;
        VideoPlayerPlatform.instance = platform;
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: [_video('lock')],
          onLocalBlocksChanged: (_) {},
        );
        final editor = adapter.editorState;
        final locks = CollabBlockLocks(
          editor: editor,
          userId: 'u1',
          canUnlock: (_) => false,
          commit: (_, _, _) async {},
        );
        editor.blockDecorator = (context, node, child) =>
            decorateCollabBlockLock(context, editor, node, child);
        locks.update([
          const CollabBlockLockState(
            blockId: 'video',
            sourceId: 'video',
            ownerId: 'u1',
          ),
        ]);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          locks.dispose();
          adapter.dispose();
          await platform.close();
          VideoPlayerPlatform.instance = original;
          await tester.binding.setSurfaceSize(null);
        });
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
                    csesVideoBlockType: CollabVideoBlockComponentBuilder(),
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (mode == 'failed') {
          platform._events.values.single.addError(
            PlatformException(
              code: 'fixture',
              message: 'expected decoder failure',
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('视频加载失败'), findsOneWidget);
        }
        final frame = tester.getRect(
          find.byKey(const ValueKey('collab-video-viewport')),
        );
        final badge = find.byKey(const ValueKey('block-lock-badge-video'));
        final rect = tester.getRect(badge);
        expect(rect.top, closeTo(frame.top - 5, 0.01));
        expect(rect.right, closeTo(frame.right + 5, 0.01));
        RenderObject child = tester.renderObject(badge);
        while (child.parent != null) {
          final parent = child.parent!;
          final clip = parent.describeApproximatePaintClip(child);
          if (clip != null) {
            final visible = MatrixUtils.transformRect(
              parent.getTransformTo(null),
              clip,
            ).inflate(0.01);
            expect(
              visible.contains(rect.topLeft),
              isTrue,
              reason: '$parent clips lock',
            );
            expect(
              visible.contains(rect.bottomRight),
              isTrue,
              reason: '$parent clips lock',
            );
          }
          child = parent;
        }
        await tester.tap(
          find.byKey(const ValueKey('block-lock-menu-trigger-video')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('block-lock-video')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('collab-video-menu-delete')),
          findsNothing,
        );
        expect(editor.undoManager.undoStack, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final targetPlatform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  ]) {
    for (final editable in [true, false]) {
      testWidgets(
        'video gestures suppress body focus on $targetPlatform editable=$editable',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(390, 844));
          final platform = _MemoryVideoPlatform(
            pending: false,
            duration: const Duration(minutes: 1),
          );
          final original = VideoPlayerPlatform.instance;
          VideoPlayerPlatform.instance = platform;
          final changes = <List<CollabEditorBlock>>[];
          final adapter = AppFlowyBlockEditorAdapter(
            initialBlocks: [
              const CollabEditorBlock(
                id: 'before',
                blockType: 'paragraph',
                text: '前置正文',
              ),
              _video('focus'),
              const CollabEditorBlock(
                id: 'after',
                blockType: 'paragraph',
                text: '后置正文',
              ),
            ],
            onLocalBlocksChanged: changes.add,
          );
          final editor = adapter.editorState;
          editor.editable = editable;
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(() => Future<void>.delayed(Duration.zero));
            adapter.dispose();
            await platform.close();
            VideoPlayerPlatform.instance = original;
            await tester.binding.setSurfaceSize(null);
            await tester.pump(const Duration(milliseconds: 500));
          });
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
                  editorState: editor,
                  editable: editable,
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
          );
          await tester.pumpAndSettle();
          for (final action in ['background', 'play', 'seek']) {
            if (editable) {
              final update = editor.updateSelectionWithReason(
                Selection.collapsed(Position(path: [0], offset: 2)),
                reason: SelectionUpdateReason.uiEvent,
              );
              await tester.pumpAndSettle();
              await update;
              expect(tester.testTextInput.hasAnyClients, isTrue);
            }
            tester.testTextInput.log.clear();
            if (action == 'background') {
              final frame = tester.getRect(
                find.byKey(const ValueKey('collab-video-viewport')),
              );
              final gesture = await tester.startGesture(
                frame.topLeft + const Offset(12, 12),
              );
              await tester.pump(const Duration(milliseconds: 150));
              expect(
                tester.testTextInput.hasAnyClients,
                isFalse,
                reason: '按下视频即关闭已有正文输入',
              );
              await gesture.up();
            } else if (action == 'play') {
              await tester.tap(
                find.byKey(const ValueKey('collab-video-block-play')),
              );
            } else {
              final track = tester.getRect(
                find.byKey(const ValueKey('collab-video-progress')),
              );
              await tester.dragFrom(
                Offset(track.left + 12, track.center.dy),
                Offset(track.width * .55, 0),
              );
            }
            await tester.pumpAndSettle();
            await tester.pump(const Duration(milliseconds: 500));
            expect(editor.selection, isNull, reason: action);
            expect(tester.testTextInput.hasAnyClients, isFalse, reason: action);
            expect(
              tester.testTextInput.log.where(
                (call) => call.method == 'TextInput.show',
              ),
              isEmpty,
              reason: action,
            );
            if (action == 'play') {
              expect(
                tester
                    .widget<VideoPlayer>(find.byType(VideoPlayer))
                    .controller
                    .value
                    .isPlaying,
                isTrue,
              );
            } else if (action == 'seek') {
              expect(platform.seeks, hasLength(1), reason: '拖动松手仍只提交一次跳转');
              expect(platform.seeks.single.$2, greaterThan(Duration.zero));
            }
          }
          await tester.tap(find.byKey(const ValueKey('block-more-video')));
          await tester.pumpAndSettle();
          expect(find.text('在外部应用打开'), findsOneWidget);
          Navigator.of(tester.element(find.text('在外部应用打开'))).pop();
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 500));
          expect(tester.testTextInput.hasAnyClients, isFalse);
          expect(changes, isEmpty);
          expect(editor.undoManager.undoStack, isEmpty);
          if (editable) {
            await tester.tap(find.byKey(editor.document.first!.key));
            await tester.pumpAndSettle();
            expect(editor.selection?.start.path, [0]);
            expect(
              tester.testTextInput.hasAnyClients,
              isTrue,
              reason: '视频交互后仍可点击正文继续输入',
            );
          }
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(targetPlatform),
      );
    }
  }

  for (final fails in [false, true]) {
    testWidgets('video placeholder suppresses focus while failed=$fails', (
      tester,
    ) async {
      final platform = _MemoryVideoPlatform(pending: true);
      final original = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = platform;
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          const CollabEditorBlock(
            id: 'before',
            blockType: 'paragraph',
            text: '正文',
          ),
          _video('loading'),
        ],
        onLocalBlocksChanged: (_) => throw TestFailure('视频点击不得写正文'),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        adapter.dispose();
        await platform.close();
        VideoPlayerPlatform.instance = original;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppFlowyEditor(
              editorState: adapter.editorState,
              blockComponentBuilders: {
                ...standardBlockComponentBuilderMap,
                csesVideoBlockType: CollabVideoBlockComponentBuilder(),
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (fails) {
        platform._events[0]!.addError(
          PlatformException(
            code: 'fixture-video-failure',
            message: 'expected initialization failure',
          ),
        );
        await tester.pumpAndSettle();
      }
      final update = adapter.editorState.updateSelectionWithReason(
        Selection.collapsed(Position(path: [0], offset: 1)),
        reason: SelectionUpdateReason.uiEvent,
      );
      await tester.pumpAndSettle();
      await update;
      expect(tester.testTextInput.hasAnyClients, isTrue);
      tester.testTextInput.log.clear();
      await tester.tap(find.byKey(const ValueKey('collab-video-viewport')));
      await tester.pumpAndSettle();
      expect(adapter.editorState.selection, isNull);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.show',
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final (size, fail) in [
    (const Size(1920, 1080), false),
    (const Size(1080, 1920), false),
    (const Size(2560, 1080), false),
    (const Size(100, 100), true),
  ]) {
    testWidgets('16:9 video frame keeps geometry for $size failure=$fail', (
      tester,
    ) async {
      final platform = _MemoryVideoPlatform(pending: true, size: size);
      final original = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = platform;
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          _video('ratio'),
          const CollabEditorBlock(
            id: 'tail-ratio',
            blockType: 'paragraph',
            text: 'after video',
          ),
        ],
        onLocalBlocksChanged: (_) =>
            throw TestFailure('rendering must not write shared props'),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        adapter.dispose();
        await platform.close();
        VideoPlayerPlatform.instance = original;
      });

      /// 构建固定编辑器及节点，初始化事件由测试显式发送。
      Widget page() => MaterialApp(
        home: Scaffold(
          body: AppFlowyEditor(
            editorState: adapter.editorState,
            disableKeyboardService: true,
            blockComponentBuilders: {
              ...standardBlockComponentBuilderMap,
              csesVideoBlockType: CollabVideoBlockComponentBuilder(),
            },
          ),
        ),
      );
      final frame = find.byKey(const ValueKey('collab-video-viewport'));
      final tail = find.text('after video', findRichText: true);
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      final before = tester.getRect(frame);
      final tailBefore = tester.getTopLeft(tail).dy;
      expect(before.width / before.height, closeTo(16 / 9, 0.001));
      if (fail) {
        platform._events[0]!.addError(
          PlatformException(
            code: 'decoder',
            message: 'fixture decoder failure',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('视频加载失败'), findsOneWidget);
      } else {
        platform._events[0]!.add(
          VideoEvent(
            eventType: VideoEventType.initialized,
            duration: platform.duration,
            size: size,
          ),
        );
        await tester.pumpAndSettle();
        final picture = tester.getRect(find.byType(VideoPlayer));
        expect(
          picture.width / picture.height,
          closeTo(size.aspectRatio, 0.001),
        );
        expect(picture.center.dx, closeTo(before.center.dx, 0.001));
        expect(picture.center.dy, closeTo(before.center.dy, 0.001));
        expect(picture.width, lessThanOrEqualTo(before.width + 0.001));
        expect(picture.height, lessThanOrEqualTo(before.height + 0.001));
        final play = tester.getRect(
          find.byKey(const ValueKey('collab-video-block-play')),
        );
        expect(play.center.dx, closeTo(before.center.dx, 0.001));
        expect(play.center.dy, closeTo(before.center.dy, 0.001));
      }
      expect(tester.getRect(frame), before);
      expect(tester.getTopLeft(tail).dy, closeTo(tailBefore, 0.001));
      expect(tester.takeException(), isNull);
    });
  }
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
        expect(
          find.byKey(const ValueKey('collab-video-menu-delete')),
          findsNothing,
        );
        expect(find.text('在外部应用打开'), findsOneWidget);
        expect(find.widgetWithText(CollabMenuRow, '播放视频'), findsNothing);
        expect(find.widgetWithText(CollabMenuRow, '暂停视频'), findsNothing);
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
  for (final pending in [false, true]) {
    for (final nested in [false, true]) {
      testWidgets(
        'video deletion is undoable and releases its player (pending=$pending, nested=$nested)',
        (tester) async {
          final platform = _MemoryVideoPlatform(pending: pending);
          final previous = VideoPlayerPlatform.instance;
          VideoPlayerPlatform.instance = platform;
          final changes = <List<CollabEditorBlock>>[];
          final adapter = AppFlowyBlockEditorAdapter(
            initialBlocks: [
              if (nested)
                const CollabEditorBlock(
                  id: 'outer',
                  blockType: 'callout',
                  text: '',
                ),
              CollabEditorBlock(
                id: 'video',
                parentId: nested ? 'outer' : null,
                blockType: csesVideoBlockType,
                text: 'https://example.test/delete.mp4',
              ),
            ],
            onLocalBlocksChanged: changes.add,
          );
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(() => Future<void>.delayed(Duration.zero));
            adapter.dispose();
            await platform.close();
            VideoPlayerPlatform.instance = previous;
          });
          await tester.pumpWidget(_videoApp(adapter));
          await tester.pumpAndSettle();
          final before = adapter.blocks;
          await tester.tap(find.byKey(const ValueKey('block-more-video')));
          await tester.pumpAndSettle();
          final deletion = find.byKey(
            const ValueKey('collab-video-menu-delete'),
          );
          expect(tester.widget<CollabMenuRow>(deletion).enabled, isTrue);
          expect(find.text('删除视频'), findsOneWidget);
          expect(find.text('在外部应用打开'), findsOneWidget);
          await tester.tap(deletion);
          await tester.pumpAndSettle();
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          expect(
            adapter.blocks.where(
              (block) => block.blockType == csesVideoBlockType,
            ),
            isEmpty,
          );
          final paragraph = adapter.blocks.singleWhere(
            (block) => block.blockType == 'paragraph',
          );
          expect(paragraph.text, isEmpty);
          expect(paragraph.parentId, nested ? 'outer' : null);
          expect(changes, hasLength(1));
          expect(platform.disposed, [0]);
          expect(adapter.editorState.undoManager.undoStack.isNonEmpty, isTrue);
          final after = adapter.blocks;
          adapter.editorState.undoManager.undo();
          await tester.pumpAndSettle();
          expect(adapter.blocks, before);
          expect(adapter.editorState.undoManager.undoStack.isEmpty, isTrue);
          adapter.editorState.undoManager.redo();
          await tester.pumpAndSettle();
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          expect(adapter.blocks, after);
          expect(platform.disposed, [0, 1]);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final change in ['permission', 'source', 'deleted']) {
    testWidgets('open video delete menu rejects stale target after $change', (
      tester,
    ) async {
      final platform = _MemoryVideoPlatform(pending: false);
      final previous = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = platform;
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [_video('before')],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        adapter.dispose();
        await platform.close();
        VideoPlayerPlatform.instance = previous;
      });
      await tester.pumpWidget(_videoApp(adapter));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('block-more-video')));
      await tester.pumpAndSettle();
      if (change == 'permission') {
        adapter.editorState.editable = false;
        adapter.editorState.editable = true;
      } else if (change == 'source') {
        await adapter.replaceFromRemote([_video('remote')]);
      } else {
        await adapter.replaceFromRemote([
          const CollabEditorBlock(
            id: 'remote',
            blockType: 'paragraph',
            text: '远端正文',
          ),
        ]);
      }
      await tester.pumpAndSettle();
      final expected = adapter.blocks;
      await tester.tap(find.byKey(const ValueKey('collab-video-menu-delete')));
      await tester.pumpAndSettle();
      expect(adapter.blocks, expected);
      expect(changes, isEmpty);
      expect(tester.takeException(), isNull);
    });
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
      final frame = tester.getRect(
        find.byKey(const ValueKey('collab-video-viewport')),
      );
      final play = tester.getRect(
        find.byKey(const ValueKey('collab-video-block-play')),
      );
      final track = tester.getRect(progress);
      final elapsed = tester.getRect(
        find.byKey(const ValueKey('collab-video-position')),
      );
      expect(play.center.dx, closeTo(frame.center.dx, 0.001));
      expect(play.center.dy, closeTo(frame.center.dy, 0.001));
      expect(track.top, greaterThanOrEqualTo(play.bottom));
      expect(elapsed.bottom, lessThanOrEqualTo(frame.bottom));
      expect(frame.width / frame.height, closeTo(16 / 9, 0.001));
      expect(picture.width / picture.height, closeTo(1, 0.01));
      if (mode == 'narrow') {
        await tester.tap(find.byKey(const ValueKey('collab-video-block-play')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<VideoPlayer>(find.byType(VideoPlayer))
              .controller
              .value
              .isPlaying,
          isTrue,
        );
      }
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

/// 用真实视频/高亮构建器展示借用的 [adapter]；播放器由各卡片拥有，测试负责卸载页面。
Widget _videoApp(AppFlowyBlockEditorAdapter adapter) => MaterialApp(
  home: Scaffold(
    body: AppFlowyEditor(
      editorState: adapter.editorState,
      disableKeyboardService: true,
      blockComponentBuilders: {
        ...standardBlockComponentBuilderMap,
        'callout': CollabCalloutBlockComponentBuilder(),
        csesVideoBlockType: CollabVideoBlockComponentBuilder(),
      },
    ),
  ),
);

/// 为 [source] 创建相同身份的视频块；仅返回投影，不创建网络资源。
CollabEditorBlock _video(String source) => CollabEditorBlock(
  id: 'video',
  blockType: csesVideoBlockType,
  text: 'https://example.test/$source.mp4',
);

/// 通过官方平台端口记录创建/释放，不使用真实解码器；测试持有流并负责 close。
class _MemoryVideoPlatform extends VideoPlayerPlatform {
  /// [pending] 为 true 时不发送初始化完成事件，用于验证加载期间换源和退出。
  /// [duration] 是模拟媒体时长，默认1秒；[size] 是原始像素尺寸，默认正方形。
  _MemoryVideoPlatform({
    required this.pending,
    this.duration = const Duration(seconds: 1),
    this.size = const Size(100, 100),
  });

  /// 模拟原始视频尺寸，不代表播放器在卡片内的显示尺寸。
  final Size size;

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
          size: size,
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
