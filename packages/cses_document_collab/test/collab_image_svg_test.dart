import 'dart:async';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_image_content.dart';
import 'package:cses_document_collab/src/model/collab_image.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

/// Returns a self-contained vector fixture marked by [color], with an XML header.
String _svg(String color) =>
    '<?xml version="1.0"?>\n'
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
    '<rect width="10" height="10" fill="$color"/></svg>';

/// Builds a stable formal image for [url], retaining layout and caption metadata.
CollabEditorBlock _image(String url) => CollabEditorBlock(
  id: 'svg-image',
  blockType: ImageBlockKeys.type,
  text: url,
  image: const CollabImage(
    widthRatio: 50,
    aspectRatio: 2,
    rotation: 10,
    captions: [CollabImageCaption(id: 'caption', text: 'SVG题注')],
  ),
);

/// Renders the borrowed [adapter] without native plugins or actual HTTP calls.
Widget _view(AppFlowyBlockEditorAdapter adapter) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 300,
      child: CollabImageContent(
        node: adapter.editorState.document.first!,
        editorState: adapter.editorState,
      ),
    ),
  ),
);

/// Advances [tester] through file futures and SVG compilation without arbitrary
/// long sleeps; the vector compiler uses a real background isolate.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

/// Supplies in-memory files via the same public cache contract as production.
/// Each test owns the fixture and restores the borrowed global cache reference.
class _Cache extends Fake implements BaseCacheManager {
  /// File system owned by this fixture; no disk files or plugins are allocated.
  final fs = MemoryFileSystem();

  /// Completed cache entries keyed by the full URL, including query strings.
  final files = <String, FileInfo>{};

  /// Delayed file results owned and completed by the test.
  final pending = <String, Completer<File>>{};

  /// Records explicit fetch requests, distinct from cache-only fallback reads.
  final fetches = <String>[];

  /// Records raster loads through CachedNetworkImage's public cache contract.
  final rasterLoads = <String>[];

  /// Records cache-only fallback lookups, which must not initiate another fetch.
  final cacheReads = <String>[];

  /// Stores [content] as the cached file associated with [url]; returns its handle.
  File add(String url, String content) {
    final file = fs.file('/${files.length}.image')..writeAsStringSync(content);
    files[url] = FileInfo(file, FileSource.Cache, DateTime(2100), url);
    return file;
  }

  /// Returns [url]'s cached/delayed file; [key] and [headers] are unused fixtures.
  /// Missing files model download errors without issuing real HTTP requests.
  @override
  Future<File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async {
    fetches.add(url);
    if (pending.containsKey(url)) return pending[url]!.future;
    final file = files[url]?.file;
    if (file == null) throw StateError('fixture download failure');
    return file;
  }

  /// Streams the raster loader's [url] entry; [key], [headers], [withProgress]
  /// do not alter the local fixture. Missing entries model HTTP failures.
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    rasterLoads.add(url);
    final info = files[url];
    if (info == null) throw StateError('fixture download failure');
    yield info;
  }

  /// Looks up [key] without fetching; [ignoreMemCache] is irrelevant in memory.
  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async {
    cacheReads.add(key);
    return files[key];
  }
}

/// Verifies vector routing, cache-only fallback, failures and stale-source isolation.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This test file owns its isolate's initial cache. Replacing the lazy default
  // before reading it avoids starting path-provider/SQLite plugins in a unit test.
  CachedNetworkImageProvider.defaultCacheManager = _Cache();
  late _Cache cache;
  late BaseCacheManager original;
  setUp(() {
    original = CachedNetworkImageProvider.defaultCacheManager;
    cache = _Cache();
    CachedNetworkImageProvider.defaultCacheManager = cache;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  tearDown(() {
    CachedNetworkImageProvider.defaultCacheManager = original;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  for (final path in [
    'logo.svg?token=test',
    'LOGO.SVG?version=2',
    'download?id=svg',
    'download?id=long-svg',
  ]) {
    testWidgets('remote SVG renders from cache at $path', (tester) async {
      final url = 'https://example.test/$path';
      cache.add(
        url,
        path.contains('long-svg')
            ? _svg('red').replaceFirst('<svg ', '<!--${'a' * 20000}--><svg ')
            : _svg('red'),
      );
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [_image(url)],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      await tester.pumpWidget(_view(adapter));
      await _settle(tester);
      expect(find.byType(SvgPicture), findsOneWidget);
      expect(find.text('图片加载失败'), findsNothing);
      expect(find.text('图片加载中'), findsNothing);
      expect(find.text('SVG题注'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('collab-image-box'))),
        const Size(150, 75),
      );
      if (path.startsWith('download')) {
        expect(cache.fetches, isEmpty);
        expect(cache.rasterLoads, [url]);
        expect(cache.cacheReads, [url]);
      } else {
        expect(cache.fetches, [url]);
        expect(cache.rasterLoads, isEmpty);
      }
      expect(changes, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  for (final failure in ['missing.svg', 'broken.svg', 'bad-image']) {
    testWidgets('SVG/raster failure stays local for $failure', (tester) async {
      final url = 'https://example.test/$failure';
      if (failure == 'broken.svg') cache.add(url, '<svg>');
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [_image(url)],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      await tester.pumpWidget(_view(adapter));
      await _settle(tester);
      expect(find.text('图片加载失败'), findsOneWidget);
      if (failure == 'bad-image') expect(cache.fetches, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('raster images still use CachedNetworkImage decoding', (
    tester,
  ) async {
    const url = 'https://example.test/photo.png';
    final file = cache.fs.file('/photo.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
    cache.files[url] = FileInfo(file, FileSource.Cache, DateTime(2100), url);
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: [_image(url)],
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);
    await tester.pumpWidget(_view(adapter));
    await _settle(tester);
    expect(find.byType(CachedNetworkImage), findsOneWidget);
    expect(find.byType(SvgPicture), findsNothing);
    expect(find.text('图片加载中'), findsNothing);
    expect(find.text('图片加载失败'), findsNothing);
    expect(cache.cacheReads, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('late SVG completion cannot overwrite the new URL', (
    tester,
  ) async {
    const first = 'https://example.test/first.svg';
    const second = 'https://example.test/second.svg';
    final firstFile = cache.add(first, _svg('red'));
    cache.add(second, _svg('blue'));
    cache.pending[first] = Completer<File>();
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: [_image(first)],
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);
    await tester.pumpWidget(_view(adapter));
    await tester.pump();
    await adapter.replaceFromRemote([_image(second)]);
    await tester.pumpWidget(_view(adapter));
    await _settle(tester);
    cache.pending[first]!.complete(firstFile);
    await _settle(tester);
    final loader =
        tester.widget<SvgPicture>(find.byType(SvgPicture)).bytesLoader
            as SvgBytesLoader;
    expect(utf8.decode(loader.bytes), contains('blue'));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('SVG data URI uses vector rendering without network/cache', (
    tester,
  ) async {
    final uri = Uri.dataFromString(
      _svg('green'),
      mimeType: 'image/svg+xml',
    ).toString();
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: [_image(uri)],
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);
    await tester.pumpWidget(_view(adapter));
    await _settle(tester);
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.text('图片加载失败'), findsNothing);
    expect(cache.fetches, isEmpty);
    expect(cache.rasterLoads, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
