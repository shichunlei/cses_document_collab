import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/editor/collab_resource_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:metalink/metalink.dart';
import 'package:cses_document_collab/src/editor/collab_link_preview.dart';

/// Returns a localized editor harness borrowing [state] and [loadPreview].
/// Null [loadPreview] uses fixture HTML; no real network request is required.
Widget _app(EditorState state, {CollabLinkPreviewLoader? loadPreview}) =>
    MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        AppFlowyEditorLocalizations.delegate,
      ],
      home: Scaffold(
        body: AppFlowyEditor(
          editorState: state,
          editable: state.editable,
          disableKeyboardService: true,
          blockComponentBuilders: {
            ...standardBlockComponentBuilderMap,
            for (final kind in collabResourceTypes)
              kind: CollabResourceBlockComponentBuilder(
                loadPreview: loadPreview ?? _metadata,
              ),
          },
        ),
      ),
    );
CollabEditorBlock _block(
  String kind,
  String url, {
  Map<String, dynamic> props = const {},
}) => CollabEditorBlock(
  id: 'resource',
  blockType: kind,
  text: url,
  resource: CollabResource.fromValues(props),
);

/// Registers resource UI, collaboration, readonly and controller lifecycle checks.
void main() {
  testWidgets(
    'attachment fields edit and undo; readonly hides editing but retains opening',
    (tester) async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          _block(
            'attachment',
            'https://example.test/a.pdf',
            props: {'name': '方案.pdf', 'size': 2048},
          ),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      await tester.pumpWidget(_app(adapter.editorState));
      await tester.pumpAndSettle();
      expect(find.text('方案.pdf'), findsOneWidget);
      expect(find.textContaining('2.0 KB'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('resource-edit-resource')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('resource-field-name')),
        '新方案.pdf',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('新方案.pdf'), findsOneWidget);
      expect(changes.last.single.resource!.propertyEdits, contains('name'));
      adapter.editorState.undoManager.undo();
      await tester.pumpAndSettle();
      expect(find.text('方案.pdf'), findsOneWidget);
      adapter.editorState.editable = false;
      await tester.pumpWidget(_app(adapter.editorState));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('resource-edit-resource')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('resource-delete-resource')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('resource-open-resource')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'bookmark displays its stored title and description and deletes cleanly',
    (tester) async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          _block(
            'bookmark',
            'https://example.test/article',
            props: {'title': '网页标题', 'description': '已保存的网页摘要'},
          ),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      await tester.pumpWidget(_app(adapter.editorState));
      await tester.pumpAndSettle();
      expect(find.text('网页标题'), findsOneWidget);
      expect(find.text('已保存的网页摘要'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('resource-delete-resource')));
      await tester.pumpAndSettle();
      expect(adapter.blocks.single.blockType, 'paragraph');
      expect(adapter.blocks.single.text, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final kind in ['bookmark', 'embed', 'figma-embed', 'juejin-embed']) {
    testWidgets(
      '$kind renders metadata from the original URL and follows remote changes',
      (tester) async {
        final loads = <String>[];
        final pending = Completer<ExtractionResult<LinkMetadata>>();
        final first = kind == 'figma-embed'
            ? 'https://www.figma.com/design/demo/Design?node-id=1-2'
            : kind == 'juejin-embed'
            ? 'https://juejin.cn/post/123'
            : 'https://example.test/page';
        final second = kind == 'figma-embed'
            ? 'https://www.figma.com/design/next/Design'
            : kind == 'juejin-embed'
            ? 'https://juejin.cn/post/456'
            : 'https://example.test/next';
        final changes = <List<CollabEditorBlock>>[];
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: [
            _block(kind, first, props: {'wr': 75, 'ar': 1.5}),
          ],
          onLocalBlocksChanged: changes.add,
        );
        addTearDown(adapter.dispose);
        Future<ExtractionResult<LinkMetadata>> loadPreview(String url) {
          loads.add(url);
          return url == first ? pending.future : _metadata(url);
        }

        await tester.pumpWidget(
          _app(adapter.editorState, loadPreview: loadPreview),
        );
        await tester.pump();
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(loads, [first]);
        await adapter.replaceFromRemote([
          _block(kind, second, props: {'wr': 50, 'ar': 2}),
        ]);
        await tester.pumpAndSettle();
        expect(loads, [first, second]);
        expect(find.text('预览标题 $second'), findsOneWidget);
        expect(find.text('提取的网页摘要'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('resource-open-resource')),
          findsNothing,
        );
        await tester.tap(find.byKey(const ValueKey('resource-edit-resource')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('resource-field-url')),
          findsOneWidget,
        );
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        final preview = find.byType(CollabLinkPreview);
        final width = tester.getSize(preview).width;
        expect(
          width,
          closeTo(tester.getSize(find.byType(LayoutBuilder).last).width / 2, 1),
        );
        pending.complete(await _metadata(first));
        await tester.pumpAndSettle();
        expect(find.text('预览标题 $first'), findsNothing);
        expect(find.text('预览标题 $second'), findsOneWidget);
        expect(changes, isEmpty);
        expect(adapter.blocks.single.resource!.number('ar'), 2);
        adapter.editorState.editable = false;
        await tester.pumpWidget(
          _app(adapter.editorState, loadPreview: loadPreview),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('resource-edit-resource')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('resource-open-resource')),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final pending in [false, true]) {
    testWidgets(
      'audio controls and source replacement release controllers (pending=$pending)',
      (tester) async {
        final old = VideoPlayerPlatform.instance;
        final platform = _AudioPlatform(pending);
        VideoPlayerPlatform.instance = platform;
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: [
            _block(
              'audio',
              'https://example.test/a.mp3',
              props: {'name': '语音'},
            ),
          ],
          onLocalBlocksChanged: (_) {},
        );
        addTearDown(() async {
          adapter.dispose();
          await platform.close();
          VideoPlayerPlatform.instance = old;
        });
        await tester.pumpWidget(_app(adapter.editorState));
        await tester.pump(const Duration(milliseconds: 100));
        if (!pending) {
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('播放音频'));
          await tester.pump();
          expect(platform.played, [0]);
          await tester.tap(find.byTooltip('暂停音频'));
          await tester.pump();
          tester.widget<Slider>(find.byType(Slider)).onChanged!(30000);
          await tester.pump();
          expect(platform.positions.last, const Duration(seconds: 30));
        }
        await adapter.replaceFromRemote([
          _block('audio', 'https://example.test/b.mp3', props: {'name': '新语音'}),
        ]);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(platform.sources, [
          'https://example.test/a.mp3',
          'https://example.test/b.mp3',
        ]);
        expect(platform.disposed, [0]);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(platform.disposed, [0, 1]);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

/// Returns metadata parsed from fixture HTML using [url] as its base address.
/// Completes without network requests or mutation of editor/shared state.
Future<ExtractionResult<LinkMetadata>> _metadata(String url) =>
    MetaLinkParser().parseHtml(
      '<html><head><meta property="og:title" content="预览标题 $url">'
      '<meta property="og:description" content="提取的网页摘要">'
      '</head></html>',
      documentUrl: Uri.parse(url),
    );

class _AudioPlatform extends VideoPlayerPlatform {
  _AudioPlatform(this.pending);
  final bool pending;
  final sources = <String>[];
  final disposed = <int>[];
  final played = <int>[];
  final positions = <Duration>[];
  final streams = <int, StreamController<VideoEvent>>{};
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = sources.length;
    sources.add(options.dataSource.uri!);
    final stream = StreamController<VideoEvent>();
    streams[id] = stream;
    if (!pending) {
      stream.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(minutes: 1),
          size: const Size(10, 10),
        ),
      );
    }
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => streams[playerId]!.stream;
  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    await streams.remove(playerId)?.close();
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> play(int playerId) async {
    played.add(playerId);
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    positions.add(position);
  }

  @override
  Future<Duration> getPosition(int playerId) async =>
      positions.lastOrNull ?? Duration.zero;
  Future<void> close() async {
    await Future.wait(streams.values.map((v) => v.close()));
    streams.clear();
  }
}
