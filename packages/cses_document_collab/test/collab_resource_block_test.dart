import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/editor/collab_audio_block.dart';
import 'package:cses_document_collab/src/editor/collab_attachment_block.dart';
import 'package:cses_document_collab/src/editor/collab_bookmark_block.dart';
import 'package:cses_document_collab/src/editor/collab_web_embed_block.dart';
import 'package:cses_document_collab/src/editor/collab_juejin_embed_block.dart';
import 'package:cses_document_collab/src/editor/collab_figma_embed_block.dart';
import 'package:cses_document_collab/src/editor/collab_card_frame.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:metalink/metalink.dart';
import 'package:cses_document_collab/src/editor/collab_link_preview.dart';

/// Returns a localized editor harness borrowing [state] and [loadPreview].
/// Null [loadPreview] uses fixture HTML; no real network request is required.
/// Optional [textScaler] overrides the platform scaling for accessibility layout checks.
Widget _app(
  EditorState state, {
  CollabLinkPreviewLoader? loadPreview,
  TextScaler? textScaler,
}) => MaterialApp(
  builder: textScaler == null
      ? null
      : (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
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
        'audio': CollabAudioBlockComponentBuilder(),
        'attachment': CollabAttachmentBlockComponentBuilder(),
        'bookmark': CollabBookmarkBlockComponentBuilder(
          loadPreview: loadPreview ?? _metadata,
        ),
        'embed': CollabWebEmbedBlockComponentBuilder(),
        'juejin-embed': CollabJuejinEmbedBlockComponentBuilder(),
        'figma-embed': CollabFigmaEmbedBlockComponentBuilder(),
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
  for (final sample in [
    (
      name: '设计方案.pdf',
      mime: '',
      bytes: 2048,
      metadata: 'PDF · 2.0 KB',
      icon: LucideIcons.fileText,
    ),
    (
      name: '项目预算.xlsx',
      mime: '',
      bytes: 1073741824,
      metadata: 'XLSX · 1.0 GB',
      icon: LucideIcons.fileSpreadsheet,
    ),
    (
      name: '下载文件',
      mime: 'application/pdf',
      bytes: 0,
      metadata: 'PDF · 0 B',
      icon: LucideIcons.fileText,
    ),
    (
      name: 'archive.7z',
      mime: '',
      bytes: 12,
      metadata: '7Z · 12 B',
      icon: LucideIcons.fileArchive,
    ),
    (
      name: '未知文件',
      mime: '',
      bytes: -1,
      metadata: '文件 · 大小未知',
      icon: LucideIcons.file,
    ),
  ]) {
    testWidgets('attachment identity shows ${sample.metadata}', (tester) async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          _block(
            'attachment',
            'https://example.test/file',
            props: {
              'name': sample.name,
              'type': sample.mime,
              'size': sample.bytes,
            },
          ),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      await tester.pumpWidget(_app(adapter.editorState));
      await tester.pumpAndSettle();
      expect(find.text(sample.name), findsOneWidget);
      expect(find.text(sample.metadata), findsOneWidget);
      expect(find.byIcon(sample.icon), findsOneWidget);
      expect(find.byType(IconButton), findsOneWidget);
      expect(find.textContaining('example.test'), findsNothing);
      expect(changes, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('attachment long name wraps on narrow screens with large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(280, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: [
        _block(
          'attachment',
          'https://example.test/file',
          props: {'name': '项目技术设计方案以及补充材料最终确认版本.pdf'},
        ),
      ],
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);
    await tester.pumpWidget(
      _app(adapter.editorState, textScaler: const TextScaler.linear(2)),
    );
    await tester.pumpAndSettle();
    final name = tester.widget<Text>(
      find.byKey(const ValueKey('attachment-file-name')),
    );
    expect(
      MediaQuery.textScalerOf(
        tester.element(find.byKey(const ValueKey('attachment-file-name'))),
      ).scale(14),
      28,
    );
    expect(name.maxLines, 2);
    expect(name.overflow, TextOverflow.ellipsis);
    expect(find.text('PDF · 大小未知'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('block-more-resource')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('resource-open-resource')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('resource-edit-resource')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('resource-delete-resource')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'attachment missing name falls back to decoded URL and unnamed label',
    (tester) async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          _block('attachment', 'https://example.test/%E8%B5%84%E6%96%99.zip'),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      await tester.pumpWidget(_app(adapter.editorState));
      await tester.pumpAndSettle();
      expect(find.text('资料.zip'), findsOneWidget);
      await adapter.replaceFromRemote([
        _block('attachment', 'https://example.test/'),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('未命名附件'), findsOneWidget);
      expect(find.text('文件 · 大小未知'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

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
      await tester.tap(find.byKey(const ValueKey('block-more-resource')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('关闭'), findsOneWidget);
      expect(find.byTooltip('更多操作'), findsOneWidget);
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
      expect(find.byType(IconButton), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('block-more-resource')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('block-insert-below-resource')),
        findsNothing,
      );
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
      expect(find.text('网页标题'), findsNWidgets(2));
      expect(find.text('已保存的网页摘要'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('resource-more-resource')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('resource-delete-resource')));
      await tester.pumpAndSettle();
      expect(adapter.blocks.single.blockType, 'paragraph');
      expect(adapter.blocks.single.text, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final kind in ['bookmark']) {
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
        await tester.tap(find.byKey(const ValueKey('resource-more-resource')));
        await tester.pumpAndSettle();
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
          closeTo(
            tester
                .getSize(
                  find
                      .ancestor(
                        of: preview,
                        matching: find.byType(LayoutBuilder),
                      )
                      .first,
                )
                .width,
            1,
          ),
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

  for (final mutation in ['reorder', 'url', 'revokeRestore']) {
    testWidgets('attachment menu protects target after $mutation', (
      tester,
    ) async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          _block('attachment', 'https://example.test/a.pdf'),
          const CollabEditorBlock(
            id: 'text',
            blockType: 'paragraph',
            text: '正文',
          ),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      await tester.pumpWidget(_app(adapter.editorState));
      await tester.pumpAndSettle();
      expect(find.byType(IconButton), findsOneWidget);
      expect(
        find.byKey(const ValueKey('resource-delete-resource')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('block-more-resource')));
      await tester.pumpAndSettle();
      if (mutation == 'revokeRestore') {
        adapter.editorState.editable = false;
        adapter.editorState.editable = true;
      } else {
        final blocks = adapter.blocks;
        await adapter.replaceFromRemote(
          mutation == 'reorder'
              ? blocks.reversed.toList()
              : [
                  _block('attachment', 'https://example.test/new.pdf'),
                  blocks.last,
                ],
        );
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('resource-delete-resource')));
      await tester.pumpAndSettle();
      expect(
        adapter.blocks.any((b) => b.id == 'resource'),
        mutation != 'reorder',
      );
      expect(adapter.blocks.any((b) => b.text == '正文'), isTrue);
      if (mutation == 'reorder') {
        adapter.editorState.undoManager.undo();
        await tester.pumpAndSettle();
        expect(adapter.blocks.last.id, 'resource');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  for (final (width, scale) in [(390.0, 1.0), (320.0, 1.5), (280.0, 2.2)]) {
    for (final mode in ['ready', 'zero', 'failure']) {
      testWidgets('audio loading/ready geometry $width/$scale/$mode', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(Size(width, 800));
        final original = VideoPlayerPlatform.instance;
        final platform = _AudioPlatform(true);
        VideoPlayerPlatform.instance = platform;
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: [
            _block(
              'audio',
              'https://example.test/loading.mp3',
              props: {'name': '语音加载'},
            ),
            const CollabEditorBlock(
              id: 'after-audio',
              blockType: 'paragraph',
              text: '音频后正文',
            ),
          ],
          onLocalBlocksChanged: (_) =>
              fail('loading must not modify the document'),
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          adapter.dispose();
          await platform.close();
          VideoPlayerPlatform.instance = original;
          await tester.binding.setSurfaceSize(null);
        });
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: AppFlowyEditor(
                editorState: adapter.editorState,
                disableKeyboardService: true,
                editorStyle: const EditorStyle.mobile(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                ),
                blockComponentBuilders: {
                  ...standardBlockComponentBuilderMap,
                  'audio': CollabAudioBlockComponentBuilder(),
                },
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        final loading = find.byKey(
          const ValueKey('collab-audio-loading-progress'),
        );
        expect(loading, findsOneWidget);
        expect(
          tester
              .widget<IconButton>(
                find.byKey(const ValueKey('resource-audio-play')),
              )
              .onPressed,
          isNull,
        );
        expect(find.text('--:--'), findsNWidgets(2));
        final before = tester.getRect(find.byType(CollabCardFrame));
        final slot = tester.getRect(
          find.ancestor(of: loading, matching: find.byType(SizedBox)).first,
        );
        final tail = find.text('音频后正文', findRichText: true);
        final tailTop = tester.getTopLeft(tail).dy;
        if (mode == 'failure') {
          platform.streams[0]!.addError(
            PlatformException(code: 'fixture', message: 'decode failed'),
          );
        } else {
          platform.streams[0]!.add(
            VideoEvent(
              eventType: VideoEventType.initialized,
              duration: mode == 'zero'
                  ? Duration.zero
                  : const Duration(minutes: 1),
              size: const Size(10, 10),
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(loading, findsNothing);
        expect(tester.getRect(find.byType(CollabCardFrame)), before);
        expect(tester.getTopLeft(tail).dy, closeTo(tailTop, .01));
        final sliderFinder = find.byKey(
          const ValueKey('collab-audio-progress'),
        );
        expect(
          tester.getRect(
            find
                .ancestor(of: sliderFinder, matching: find.byType(SizedBox))
                .first,
          ),
          slot,
        );
        if (mode == 'ready') {
          expect(tester.widget<Slider>(sliderFinder).onChanged, isNotNull);
          platform.streams[0]!.add(
            VideoEvent(eventType: VideoEventType.bufferingStart),
          );
          await tester.pump();
          await tester.pump();
          expect(loading, findsOneWidget);
          expect(tester.getRect(find.byType(CollabCardFrame)), before);
          platform.streams[0]!.add(
            VideoEvent(eventType: VideoEventType.bufferingEnd),
          );
          await tester.pumpAndSettle();
          expect(loading, findsNothing);
          final slider = tester.widget<Slider>(sliderFinder);
          slider.onChanged!(30000);
          slider.onChangeEnd!(30000);
          await tester.pumpAndSettle();
          expect(platform.positions, [const Duration(seconds: 30)]);
        } else {
          expect(tester.widget<Slider>(sliderFinder).onChanged, isNull);
        }
        expect(tester.takeException(), isNull);
      });
    }
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
          expect(find.byType(IconButton), findsNWidgets(2));
          await tester.tap(find.byTooltip('播放音频'));
          await tester.pumpAndSettle();
          expect(platform.played, [0]);
          await tester.tap(find.byTooltip('暂停音频'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('block-more-resource')));
          await tester.pumpAndSettle();
          expect(find.widgetWithText(ListTile, '播放音频'), findsNothing);
          expect(find.widgetWithText(ListTile, '暂停音频'), findsNothing);
          await tester.tapAt(const Offset(5, 5));
          await tester.pumpAndSettle();
          final progress = find.byKey(const ValueKey('collab-audio-progress'));
          final slider = tester.widget<Slider>(progress);
          slider.onChanged!(30000);
          await tester.pump();
          expect(platform.positions, isEmpty, reason: '拖动只预览，松手才跳转');
          expect(find.text('00:30'), findsOneWidget);
          expect(find.text('01:00'), findsOneWidget);
          slider.onChangeEnd!(30000);
          await tester.pumpAndSettle();
          expect(platform.positions, [const Duration(seconds: 30)]);
          adapter.editorState.editable = false;
          await tester.pumpAndSettle();
          expect(find.byTooltip('更多操作'), findsNothing);
          expect(find.byTooltip('播放音频'), findsOneWidget);
          expect(platform.disposed, isEmpty);
          final track = tester.getRect(progress);
          await tester.dragFrom(
            Offset(track.left + track.width * .25, track.center.dy),
            Offset(track.width * .5, 0),
          );
          await tester.pumpAndSettle();
          expect(platform.positions, hasLength(2));
          expect(platform.positions.last.inSeconds, inInclusiveRange(30, 60));
          expect(
            tester.widget<Slider>(progress).activeColor,
            const Color(0xFF818CF8),
          );
          platform.seekGate = Completer<void>();
          final pendingSlider = tester.widget<Slider>(progress);
          pendingSlider.onChanged!(40000);
          pendingSlider.onChangeEnd!(40000);
          await tester.pump();
        }
        await adapter.replaceFromRemote([
          _block('audio', 'https://example.test/b.mp3', props: {'name': '新语音'}),
        ]);
        await tester.pump(const Duration(milliseconds: 100));
        if (!pending) {
          expect(platform.disposed, isEmpty, reason: '旧跳转完成前不能释放播放器');
          platform.seekGate!.complete();
        }
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

  /// 可选跳转阻塞器，验证换源关闭等待旧操作。
  Completer<void>? seekGate;
  final streams = <int, StreamController<VideoEvent>>{};
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = sources.length;
    sources.add(options.dataSource.uri!);
    // Ownership transfers to streams; dispose/close await every retained sink.
    // ignore: close_sinks
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

  /// 为[playerId]记录目标[position]，可由测试延迟完成以验证资源关闭顺序。
  @override
  Future<void> seekTo(int playerId, Duration position) async {
    positions.add(position);
    await seekGate?.future;
  }

  @override
  Future<Duration> getPosition(int playerId) async =>
      positions.lastOrNull ?? Duration.zero;
  Future<void> close() async {
    await Future.wait(streams.values.map((v) => v.close()));
    streams.clear();
  }
}
