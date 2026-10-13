import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:cses_mobile_collab_demo/src/collab/collab_resource.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_resource_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

Widget _app(EditorState state) => MaterialApp(
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
          kind: CollabResourceBlockComponentBuilder(),
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

  for (final kind in ['embed', 'figma-embed', 'juejin-embed']) {
    testWidgets(
      '$kind embeds the correct URL and replaces its page on remote changes',
      (tester) async {
        final platform = _WebPlatform();
        WebViewPlatform.instance = platform;
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
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: [
            _block(kind, first, props: {'wr': 75, 'ar': 1.5}),
          ],
          onLocalBlocksChanged: (_) {},
        );
        addTearDown(adapter.dispose);
        await tester.pumpWidget(_app(adapter.editorState));
        await tester.pumpAndSettle();
        expect(find.text('内嵌网页'), findsOneWidget);
        expect(platform.loads.single, collabResourceFrameUrl(kind, first));
        if (kind == 'figma-embed') {
          expect(platform.loads.single.queryParameters['url'], first);
        }
        final old = platform.controllers.single.delegate!;
        expect(
          await old.navigation!(
            const NavigationRequest(url: 'javascript:bad', isMainFrame: true),
          ),
          NavigationDecision.prevent,
        );
        await adapter.replaceFromRemote([
          _block(kind, second, props: {'wr': 50, 'ar': 2}),
        ]);
        await tester.pumpAndSettle();
        expect(platform.loads.last, collabResourceFrameUrl(kind, second));
        old.progress?.call(1);
        await tester.pump();
        expect(find.byType(LinearProgressIndicator), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        old.progress?.call(50);
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

class _WebPlatform extends WebViewPlatform {
  final loads = <Uri>[];
  final controllers = <_WebController>[];
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final c = _WebController(params, loads);
    controllers.add(c);
    return c;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _Navigation(params);
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _WebWidget(params);
}

class _WebController extends PlatformWebViewController {
  _WebController(super.params, this.loads) : super.implementation();
  final List<Uri> loads;
  _Navigation? delegate;
  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}
  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate delegate,
  ) async {
    this.delegate = delegate as _Navigation;
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loads.add(params.uri);
    delegate?.progress?.call(100);
  }
}

class _Navigation extends PlatformNavigationDelegate {
  _Navigation(super.params) : super.implementation();
  ProgressCallback? progress;
  NavigationRequestCallback? navigation;
  @override
  Future<void> setOnProgress(ProgressCallback callback) async {
    progress = callback;
  }

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async {
    navigation = callback;
  }

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async {}
}

class _WebWidget extends PlatformWebViewWidget {
  _WebWidget(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Colors.white,
    child: Center(child: Text('内嵌网页')),
  );
}

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
