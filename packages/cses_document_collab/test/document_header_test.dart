import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/document_header.dart';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/model/document_cover_catalog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/memory.dart';
import 'package:file/file.dart' as files;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// 可配置头部详情与ACK延迟的测试服务，不创建网络资源，记录所有业务命令。
class _Service implements DocumentMetadataService {
  bool editable = true;
  Completer<void>? pending;
  String name = '桌面文档标题';
  Map<String, dynamic>? icon = {'type': 'emoji', 'value': '😘'};
  Map<String, dynamic>? banner = {
    'url': 'https://example.test/cover.png',
    'y': 25,
    'x': 8,
  };
  final patches = <DocumentMetadataPatch>[];

  /// 为固定测试文档 [id] 返回当前权限和字段快照；不改变正文或发请求。
  @override
  Future<DocumentMetadata> load(String id) async => DocumentMetadata(
    id: id,
    name: name,
    icon: icon,
    banner: banner,
    canRename: editable,
    canChangeAppearance: editable,
  );

  /// 记录 [id] 的 [patch] 并等待可选测试ACK；成功/异常由测试控制。
  @override
  Future<void> update(String id, DocumentMetadataPatch patch) async {
    patches.add(patch);
    if (pending != null) await pending!.future;
  }
}

/// 使用固定SVG文件模拟图标上传，持有可控结果并记录取消令牌。
class _IconUpload extends EditorMediaUploadService {
  final kinds = <String>[];
  CancelToken? token;
  Completer<EditorMediaSource>? pending;
  static const file = EditorLocalFile(
    path: '/tmp/icon.svg',
    name: '自定义图标.svg',
    size: 100,
    mimeType: 'image/svg+xml',
  );

  /// 记录所选资源 [kind] 并返回固定文件，不打开系统选择器。
  @override
  Future<EditorLocalFile?> pickFile(String kind) async {
    kinds.add(kind);
    return file;
  }

  /// 记录 [file] 的 [kind] 上传，借用 [cancelToken]，通过 [onProgress] 报告50%进度。
  /// 返回稳定测试URL或等待测试控制的Future，不创建网络任务。
  @override
  Future<EditorMediaSource> upload(
    EditorLocalFile file,
    String kind, {
    required CancelToken cancelToken,
    required void Function(double) onProgress,
  }) async {
    kinds.add(kind);
    token = cancelToken;
    onProgress(.5);
    return pending == null
        ? const EditorMediaSource('https://example.test/uploaded.svg')
        : pending!.future;
  }
}

/// 为[description]注册[callback]，图片由内存文件缓存提供，保留真实矢量解码。
void svgTestWidgets(String description, WidgetTesterCallback callback) =>
    testWidgets(description, callback);

/// 在真实异步区域等待[tester]的内存缓存读取和矢量后台编译。
Future<void> _settleImages(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// 头部测试独占的内存缓存，不启动磁盘插件或真实下载。
class _HeaderCache extends Fake implements BaseCacheManager {
  /// 此替身独占的内存文件系统。
  final fs = MemoryFileSystem();

  /// 记录缓存下载调用，验证展示未绕过共享管理器。
  final fetches = <String>[];

  /// 记录位图加载调用，保留完整URL身份。
  final rasterLoads = <String>[];

  /// 为[url]提供本地SVG/PNG；包含missing的地址模拟加载失败。
  Future<files.File> _file(String url) async {
    if (url.contains('missing')) throw StateError('fixture cache failure');
    final file = fs.file('/${url.hashCode}.image');
    if (Uri.parse(url).path.toLowerCase().endsWith('.svg') ||
        url.contains('vector-no-extension')) {
      file.writeAsStringSync(
        await File(
          'test/fixtures/document-header-image-icon.svg',
        ).readAsString(),
      );
    } else {
      file.writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
    }
    return file;
  }

  /// 记录[url]下载并返回内存文件；[key]与[headers]不改变测试来源。
  @override
  Future<files.File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async {
    fetches.add(url);
    return _file(url);
  }

  /// 为[url]返回缓存流；[key]、[headers]和[withProgress]不产生外部副作用。
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    rasterLoads.add(url);
    yield FileInfo(await _file(url), FileSource.Cache, DateTime(2100), url);
  }

  /// 按[key]仅读取既有内存文件；[ignoreMemCache]不影响本替身。
  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async {
    final file = fs.file('/${key.hashCode}.image');
    return file.existsSync()
        ? FileInfo(file, FileSource.Cache, DateTime(2100), key)
        : null;
  }
}

/// 注册正式头部界面回归，逐例创建并关闭元数据控制器和编辑器，验证业务保存、焦点与布局。
/// 本函数同步完成用例注册；异步验证及资源释放由测试框架执行。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  CachedNetworkImageProvider.defaultCacheManager = _HeaderCache();
  late _HeaderCache cache;
  late BaseCacheManager originalCache;
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(0.0),
          ),
        );
  });
  late _Service service;
  late DocumentMetadataController controller;
  late AppFlowyBlockEditorAdapter adapter;
  Future<void> mount(
    WidgetTester tester, {
    bool preview = false,
    Size size = const Size(390, 844),
    double textScale = 1,
  }) async {
    await tester.binding.setSurfaceSize(size);
    await controller.refresh();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
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
            editorState: adapter.editorState,
            editorStyle: const EditorStyle.mobile(),
            header: DocumentHeader(
              controller: controller,
              editorState: adapter.editorState,
              preview: preview,
            ),
          ),
        ),
      ),
    );
    await _settleImages(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    });
  }

  setUp(() {
    originalCache = CachedNetworkImageProvider.defaultCacheManager;
    cache = _HeaderCache();
    CachedNetworkImageProvider.defaultCacheManager = cache;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    service = _Service();
    controller = DocumentMetadataController(
      documentId: 'doc',
      service: service,
      canEdit: () => true,
    );
    adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [
        CollabEditorBlock(id: 'body', blockType: 'paragraph', text: '原始正文'),
      ],
      onLocalBlocksChanged: (_) {},
    );
  });
  tearDown(() async {
    CachedNetworkImageProvider.defaultCacheManager = originalCache;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await controller.close();
    adapter.dispose();
  });
  testWidgets(
    'business title, emoji and banner render outside body; preview hides editing',
    (tester) async {
      await mount(tester, preview: true);
      expect(find.text('桌面文档标题'), findsOneWidget);
      expect(find.text('😘'), findsOneWidget);
      final image = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage).first,
      );
      expect(image.alignment, const Alignment(0, -0.5));
      expect(find.byKey(const ValueKey('document-banner-edit')), findsNothing);
      expect(adapter.blocks.single.blockType, 'paragraph');
      expect(adapter.blocks.single.text, '原始正文');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'cached cover keeps crop, handles SVG and remote source replacement',
    (tester) async {
      const svgUrl = 'https://example.test/cover.SVG?token=one';
      service.banner = {'url': svgUrl, 'y': 75};
      await mount(tester, preview: true);
      var svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(svg.fit, BoxFit.cover);
      expect(svg.alignment, const Alignment(0, .5));
      expect(cache.fetches, [svgUrl]);
      service.banner = {'url': svgUrl, 'y': 150};
      await controller.refresh();
      await _settleImages(tester);
      svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(svg.alignment, const Alignment(0, 1));
      expect(cache.fetches, [svgUrl], reason: '调位置无需重新读取SVG');
      service.banner = {'url': 'https://example.test/new-cover.png', 'y': 0};
      await controller.refresh();
      await _settleImages(tester);
      expect(find.byType(SvgPicture), findsNothing);
      final raster = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(raster.imageUrl, 'https://example.test/new-cover.png');
      expect(raster.alignment, const Alignment(0, -1));
      service.banner = {'url': 'https://example.test/missing.svg'};
      await controller.refresh();
      await _settleImages(tester);
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(service.patches, isEmpty);
      expect(adapter.blocks.single.text, '原始正文');
      expect(tester.takeException(), isNull);
    },
  );

  for (final url in [
    'http://attachment.example.test/header.svg',
    'https://attachment.example.test/header.SVG?version=2#icon',
    'https://attachment.example.test/vector-no-extension?version=2',
  ]) {
    svgTestWidgets('image icon SVG uses vector renderer: $url', (tester) async {
      service.icon = {'type': 'image', 'value': url};
      await mount(tester, preview: true);
      if (url.contains('vector-no-extension')) {
        await _settleImages(tester);
      }
      final svgFinder = find.descendant(
        of: find.byKey(const ValueKey('document-icon-edit')),
        matching: find.byType(SvgPicture),
      );
      expect(svgFinder, findsOneWidget);
      final svg = tester.widget<SvgPicture>(svgFinder);
      expect(svg.bytesLoader, isA<SvgBytesLoader>());
      expect([...cache.fetches, ...cache.rasterLoads], contains(url));
      expect(svg.width, 48);
      expect(svg.height, 48);
      expect(svg.colorFilter, isNull); // 保留原始多色 SVG。
      expect(
        find.descendant(
          of: svgFinder,
          matching: find.byIcon(Icons.description_outlined),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      expect(controller.value!.icon, service.icon);
      expect(service.patches, isEmpty);
      expect(adapter.blocks.single.text, '原始正文');
    });
  }
  test(
    'desktop multi-color image SVG decodes and retains its green and cream fills',
    () async {
      final source = await File(
        'test/fixtures/document-header-image-icon.svg',
      ).readAsString();
      final info = await vg.loadPicture(SvgStringLoader(source), null);
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
        ..scale(48 / info.size.width, 48 / info.size.height)
        ..drawPicture(info.picture);
      final picture = recorder.endRecording();
      final image = await picture.toImage(48, 48);
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        final colors = <int>{};
        for (var i = 0; i < bytes.length; i += 4) {
          if (bytes[i + 3] == 255) {
            colors.add((bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2]);
          }
        }
        expect(colors, containsAll([0xa8bf8e, 0xe0e3be, 0x518752]));
      } finally {
        image.dispose();
        picture.dispose();
        info.picture.dispose();
      }
    },
  );

  svgTestWidgets(
    'raster image icons keep their renderer and SVG provides an error fallback',
    (tester) async {
      service.icon = {
        'type': 'image',
        'value': 'https://attachment.example.test/photo.png',
      };
      await mount(tester, preview: true);
      final area = find.byKey(const ValueKey('document-icon-edit'));
      final image = tester.widget<CachedNetworkImage>(
        find.descendant(of: area, matching: find.byType(CachedNetworkImage)),
      );
      expect(image.imageUrl, service.icon!['value']);
      expect(cache.rasterLoads, contains(service.icon!['value']));
      expect(
        find.descendant(of: area, matching: find.byType(SvgPicture)),
        findsNothing,
      );
      service.icon = {
        'type': 'image',
        'value': 'https://attachment.example.test/missing.svg',
      };
      await controller.refresh();
      await tester.pumpAndSettle();
      await _settleImages(tester);
      expect(
        find.descendant(
          of: area,
          matching: find.byIcon(Icons.description_outlined),
        ),
        findsOneWidget,
      );
      expect(controller.value!.icon, service.icon);
      expect(tester.takeException(), isNull);
    },
  );

  svgTestWidgets(
    'image icon can be replaced by a SVG link and removed through the business service',
    (tester) async {
      service.icon = {
        'type': 'image',
        'value': 'https://attachment.example.test/old.png',
      };
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('document-icon-edit')));
      await tester.pumpAndSettle();
      expect(find.text('修改图标'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('editor-media-link-tab')));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('editor-url-block-input'));
      expect(
        tester.widget<TextField>(input).controller!.text,
        service.icon!['value'],
      );
      const url = 'https://attachment.example.test/new.svg?version=2';
      await tester.enterText(input, url);
      await tester.tap(find.byKey(const ValueKey('editor-url-block-submit')));
      await tester.pumpAndSettle();
      expect(controller.value!.icon, {'type': 'image', 'value': url});
      expect(service.patches.last.icon, {'type': 'image', 'value': url});
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(find.byKey(const ValueKey('document-icon-edit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('document-icon-remove')));
      await tester.pumpAndSettle();
      expect(controller.value!.icon, isNull);
      expect(service.patches.last.changesIcon, isTrue);
      expect(service.patches.last.icon, isNull);
      expect(adapter.blocks.single.text, '原始正文');
      expect(adapter.editorState.undoManager.undoStack, isEmpty);
    },
  );
  void useUpload(_IconUpload upload) {
    final owner = Object();
    CollabRuntime.acquire(owner, CollabHostServices(mediaUpload: upload));
    addTearDown(() => CollabRuntime.release(owner));
  }

  svgTestWidgets(
    'icon emoji tab has no input; tabs preserve link and file and upload an image icon',
    (tester) async {
      final upload = _IconUpload();
      useUpload(upload);
      await mount(tester);
      final state = adapter.editorState;
      final original = Selection.single(path: [0], startOffset: 2);
      final selection = state.updateSelectionWithReason(
        original,
        reason: SelectionUpdateReason.uiEvent,
      );
      await tester.pump();
      await selection;
      await tester.pump(const Duration(milliseconds: 150));
      await tester.tap(find.byKey(const ValueKey('document-icon-edit')));
      await tester.pumpAndSettle();
      expect(find.text('表情符号'), findsOneWidget);
      expect(find.text('上传'), findsOneWidget);
      expect(find.text('链接'), findsOneWidget);
      expect(find.byKey(const ValueKey('document-icon-image')), findsNothing);
      expect(find.byKey(const ValueKey('document-emoji-input')), findsNothing);
      expect(
        find.byKey(const ValueKey('document-header-submit')),
        findsNothing,
      );
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('🚀'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('editor-media-link-tab')));
      await tester.pumpAndSettle();
      final link = find.byKey(const ValueKey('editor-url-block-input'));
      const url = 'https://example.test/new.svg';
      await tester.enterText(link, url);
      await tester.tap(find.byKey(const ValueKey('editor-media-upload-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-media-pick-file')));
      await tester.pumpAndSettle();
      expect(find.text('自定义图标.svg'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('document-icon-emoji-tab')));
      await tester.pumpAndSettle();
      expect(find.text('🚀'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      await tester.tap(find.byKey(const ValueKey('editor-media-link-tab')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(link).controller!.text, url);
      await tester.tap(find.byKey(const ValueKey('editor-media-upload-tab')));
      await tester.pumpAndSettle();
      expect(find.text('自定义图标.svg'), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(service.patches, isEmpty);
      expect(state.selection, isNull);
      await tester.tap(find.byKey(const ValueKey('editor-url-block-submit')));
      // Complete route dismissal and AppFlowy's guarded Android keyboard retry.
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(upload.kinds, ['document_icon', 'document_icon']);
      expect(service.patches.single.icon, {
        'type': 'image',
        'value': 'https://example.test/uploaded.svg',
      });
      expect(controller.value!.icon, service.patches.single.icon);
      expect(find.byType(BottomSheet), findsNothing);
      expect(state.selection, original);
      expect(adapter.blocks.single.text, '原始正文');
      expect(adapter.editorState.undoManager.undoStack, isEmpty);
    },
  );

  for (final close in [true, false]) {
    testWidgets(
      close
          ? 'closing icon upload cancels and ignores its late result'
          : 'readonly during icon upload blocks saving and source switches',
      (tester) async {
        final upload = _IconUpload()..pending = Completer<EditorMediaSource>();
        useUpload(upload);
        await mount(tester);
        await tester.tap(find.byKey(const ValueKey('document-icon-edit')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('editor-media-upload-tab')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('editor-media-pick-file')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('editor-url-block-submit')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('document-icon-emoji-tab')));
        await tester.pumpAndSettle();
        expect(find.text('🚀'), findsNothing);
        if (close) {
          await tester.tap(
            find.byKey(const ValueKey('editor-media-source-close')),
          );
          await tester.pumpAndSettle();
          expect(upload.token!.isCancelled, isTrue);
        } else {
          service.editable = false;
          await controller.refresh();
        }
        upload.pending!.complete(
          const EditorMediaSource('https://example.test/late.svg'),
        );
        await tester.pumpAndSettle();
        expect(service.patches, isEmpty);
        expect(controller.value!.icon, service.icon);
        expect(adapter.blocks.single.text, '原始正文');
        if (!close) {
          expect(find.text('文档已进入只读，请关闭面板后重新查看'), findsOneWidget);
          await tester.tap(
            find.byKey(const ValueKey('document-icon-emoji-tab')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('🚀'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('document-icon-remove')));
          await tester.pumpAndSettle();
          expect(service.patches, isEmpty);
          expect(find.byType(BottomSheet), findsOneWidget);
        }
      },
    );
  }

  testWidgets(
    'icon tabs fit narrow screens with scaled text and no upload service',
    (tester) async {
      await mount(tester, size: const Size(320, 844), textScale: 1.5);
      await tester.tap(find.byKey(const ValueKey('document-icon-edit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-media-upload-tab')));
      await tester.pumpAndSettle();
      expect(find.text('当前环境暂不支持图片上传，请使用表情或链接'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('editor-url-block-submit')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('editor-media-link-tab')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('editor-url-block-input')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cover controls remain on the image on a narrow screen with large text',
    (tester) async {
      await mount(tester, size: const Size(320, 844), textScale: 1.5);
      final cover = tester.getRect(
        find.byKey(const ValueKey('document-banner-image')),
      );
      final actions = tester.getRect(
        find.byKey(const ValueKey('document-banner-actions')),
      );
      expect(cover.left, 0);
      expect(cover.right, 320);
      expect(actions.center.dx, closeTo(cover.center.dx, 0.5));
      expect(actions.center.dy, closeTo(cover.center.dy, 0.5));
      for (final key in [
        'document-banner-edit',
        'document-banner-remove',
        'document-banner-position',
      ]) {
        final button = tester.getRect(find.byKey(ValueKey(key)));
        expect(cover.contains(button.topLeft), isTrue);
        expect(cover.contains(button.bottomRight), isTrue);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('removing the cover directly keeps the icon and body unchanged', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('document-banner-remove')));
    await tester.pumpAndSettle();
    expect(controller.value!.banner, isNull);
    expect(controller.value!.icon, service.icon);
    expect(service.patches.last.changesBanner, isTrue);
    expect(service.patches.last.banner, isNull);
    expect(find.byKey(const ValueKey('document-banner-image')), findsNothing);
    expect(find.text('添加封面'), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const ValueKey('document-icon-edit'))).left,
      20,
    );
    expect(adapter.blocks.single.text, '原始正文');
    expect(adapter.editorState.undoManager.undoStack, isEmpty);
  });

  testWidgets(
    'header without a cover uses the same text inset without negative icon positioning',
    (tester) async {
      service.banner = null;
      await mount(tester, preview: true);
      expect(find.byKey(const ValueKey('document-banner-image')), findsNothing);
      final icon = tester.getRect(
        find.byKey(const ValueKey('document-icon-edit')),
      );
      final title = tester.getRect(find.text(service.name));
      expect(icon.left, 20);
      expect(title.left, 20);
      expect(title.top, greaterThanOrEqualTo(icon.bottom));
      expect(
        find.byKey(const ValueKey('document-banner-actions')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'title and emoji save through business service without changing body or undo',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('document-title-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('document-title-input')),
        '手机标题',
      );
      await tester.tap(find.byKey(const ValueKey('document-header-submit')));
      await tester.pumpAndSettle();
      expect(controller.value!.name, '手机标题');
      await tester.tap(find.byKey(const ValueKey('document-icon-edit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('🚀'));
      await tester.pumpAndSettle();
      expect(controller.value!.icon, {'type': 'emoji', 'value': '🚀'});
      expect(service.patches, hasLength(2));
      expect(adapter.blocks.single.text, '原始正文');
      expect(adapter.editorState.undoManager.undoStack, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'gallery selection saves the original CSES URL after restoring the body caret',
    (tester) async {
      await mount(tester);
      final state = adapter.editorState;
      final original = Selection.single(path: [0], startOffset: 2);
      final selection = state.updateSelectionWithReason(
        original,
        reason: SelectionUpdateReason.uiEvent,
      );
      await tester.pump();
      await selection;
      await tester.pump(const Duration(milliseconds: 150));
      final pending = service.pending = Completer<void>();
      addTearDown(() {
        if (!pending.isCompleted) pending.complete();
      });
      await tester.tap(find.byKey(const ValueKey('document-banner-edit')));
      await tester.pumpAndSettle();
      expect(find.text('公共图库'), findsOneWidget);
      expect(find.text('上传'), findsOneWidget);
      expect(find.text('链接'), findsOneWidget);
      final image = documentCoverGroups.last.items[1];
      final tile = find.byKey(ValueKey('document-cover-${image.id}'));
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(BottomSheet), findsNothing);
      expect(state.selection, original);
      expect(controller.saving, isTrue);
      expect(controller.value!.banner, service.banner);
      expect(service.patches.single.banner, {
        ...service.banner!,
        'url': image.url,
        'y': 0,
      });
      expect(image.url, isNot(image.previewUrl));
      pending.complete();
      await tester.pumpAndSettle();
      expect(controller.value!.banner, service.patches.single.banner);
      expect(adapter.blocks.single.text, '原始正文');
      expect(state.undoManager.undoStack, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cover URL saves and removal uses explicit null; position preserves other fields',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('document-banner-edit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-media-link-tab')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('editor-url-block-input')),
        'https://example.test/new.png',
      );
      await tester.tap(find.byKey(const ValueKey('editor-url-block-submit')));
      await tester.pumpAndSettle();
      expect(controller.value!.banner!['url'], 'https://example.test/new.png');
      expect(controller.value!.banner!['x'], 8);
      await tester.tap(find.byKey(const ValueKey('document-banner-position')));
      await tester.pumpAndSettle();
      final preview = find.byKey(
        const ValueKey('document-banner-position-drag'),
      );
      final rect = tester.getRect(preview);
      expect(find.byType(Slider), findsNothing);
      await tester.drag(preview, Offset(0, -rect.height * .6));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('document-header-submit')));
      await tester.pumpAndSettle();
      expect(controller.value!.banner!['y'] as num, inInclusiveRange(40, 60));
      expect(controller.value!.banner!['x'], 8);
      await tester.tap(find.byKey(const ValueKey('document-banner-edit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-cover-url-remove')));
      await tester.pumpAndSettle();
      expect(controller.value!.banner, isNull);
      expect(service.patches.last.changesBanner, isTrue);
      expect(service.patches.last.banner, isNull);
      expect(adapter.blocks.single.text, '原始正文');
      expect(tester.takeException(), isNull);
    },
  );
  for (final mode in ['cancel', 'save', 'bounds', 'revoke']) {
    testWidgets(
      'cover direct vertical drag supports $mode without early writes',
      (tester) async {
        service.banner = {
          'url': 'https://example.test/cover.png',
          'y': 50,
          'x': 8,
          'custom': 'keep',
        };
        await mount(tester, size: const Size(320, 844), textScale: 1.5);
        final before = Map<String, dynamic>.from(controller.value!.banner!);
        await tester.tap(
          find.byKey(const ValueKey('document-banner-position')),
        );
        await tester.pumpAndSettle();
        final preview = find.byKey(
          const ValueKey('document-banner-position-drag'),
        );
        final rect = tester.getRect(preview);
        expect(find.byType(Slider), findsNothing);
        final imageFinder = find.descendant(
          of: preview,
          matching: find.byType(CachedNetworkImage),
        );
        double alignment() =>
            tester.widget<CachedNetworkImage>(imageFinder).alignment.y;
        expect(alignment(), 0);
        await tester.drag(preview, Offset(rect.width * .3, 0));
        await tester.pumpAndSettle();
        expect(alignment(), 0, reason: '横向手势不改变纵向位置');
        await tester.drag(preview, Offset(0, -rect.height * .35));
        await tester.pumpAndSettle();
        expect(alignment(), greaterThan(0), reason: '向上拖动，图片向上移动');
        expect(service.patches, isEmpty);
        expect(controller.value!.banner, before);
        if (mode == 'bounds') {
          await tester.drag(preview, Offset(0, -rect.height * 3));
          await tester.pumpAndSettle();
          expect(alignment(), 1);
          await tester.drag(preview, Offset(0, rect.height * 3));
          await tester.pumpAndSettle();
          expect(alignment(), -1);
        } else {
          final previous = alignment();
          await tester.drag(preview, Offset(0, rect.height * .2));
          await tester.pumpAndSettle();
          expect(alignment(), lessThan(previous), reason: '向下拖动，图片向下移动');
        }
        final target = ((alignment() + 1) * 50).round();
        if (mode == 'revoke') {
          service.editable = false;
          await controller.refresh();
          await tester.pumpAndSettle();
        }
        await tester.tap(
          mode == 'cancel'
              ? find.text('取消')
              : find.byKey(const ValueKey('document-header-submit')),
        );
        await tester.pumpAndSettle();
        expect(preview, findsNothing, reason: '拖动没有下拉关闭弹窗，仍可保存或取消');
        if (mode == 'cancel' || mode == 'revoke') {
          expect(service.patches, isEmpty);
          expect(controller.value!.banner, before);
        } else {
          expect(service.patches, hasLength(1));
          expect(controller.value!.banner, {...before, 'y': target});
        }
        expect(adapter.blocks.single.text, '原始正文');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('body caret is restored before a slow business save completes', (
    tester,
  ) async {
    await mount(tester);
    final state = adapter.editorState;
    final original = Selection.single(path: [0], startOffset: 2);
    final selection = state.updateSelectionWithReason(
      original,
      reason: SelectionUpdateReason.uiEvent,
    );
    await tester.pump();
    await selection;
    await tester.pump(const Duration(milliseconds: 150));
    final header = find.byKey(const ValueKey('formal-document-header'));
    final action = find.byKey(const ValueKey('document-title-action'));
    final body = find.byKey(state.document.first!.key);
    final headerSize = tester.getSize(header);
    final actionBounds = tester.getRect(action);
    final bodyTop = tester.getTopLeft(body).dy;
    final pending = service.pending = Completer<void>();
    addTearDown(() {
      if (!pending.isCompleted) pending.complete();
    });
    await tester.tap(find.byKey(const ValueKey('document-title-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('document-title-input')),
      '等待保存',
    );
    await tester.tap(find.byKey(const ValueKey('document-header-submit')));
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(controller.saving, isTrue);
    expect(find.byKey(const ValueKey('document-title-saving')), findsOneWidget);
    expect(find.text('正在保存…'), findsNothing);
    expect(tester.getSize(header), headerSize);
    expect(tester.getRect(action), actionBounds);
    expect(tester.getTopLeft(body).dy, bodyTop);
    expect(service.patches, hasLength(1));
    expect(controller.value!.name, '桌面文档标题');
    expect(state.selection, original);
    pending.complete();
    await tester.pumpAndSettle();
    expect(controller.value!.name, '等待保存');
    expect(find.byKey(const ValueKey('document-title-saving')), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(tester.getSize(header), headerSize);
    expect(tester.getRect(action), actionBounds);
    expect(tester.getTopLeft(body).dy, bodyTop);
    expect(adapter.blocks.single.text, '原始正文');
  });
  testWidgets(
    'saving keeps missing cover and icon controls stable; failure restores title editing',
    (tester) async {
      service.banner = null;
      service.icon = null;
      service.name = '文档标题文档标题文档';
      await mount(tester, size: const Size(360, 844));
      final header = find.byKey(const ValueKey('formal-document-header'));
      final action = find.byKey(const ValueKey('document-title-action'));
      final headerSize = tester.getSize(header);
      final actionBounds = tester.getRect(action);
      final pending = service.pending = Completer<void>();
      addTearDown(() {
        if (!pending.isCompleted) pending.complete();
      });
      await tester.tap(find.byKey(const ValueKey('document-title-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('document-title-input')),
        '等待保存',
      );
      await tester.tap(find.byKey(const ValueKey('document-header-submit')));
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(controller.saving, isTrue);
      expect(tester.getSize(header), headerSize);
      expect(tester.getRect(action), actionBounds);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('document-banner-edit')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('document-icon-edit')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(action);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(BottomSheet), findsNothing);
      expect(service.patches, hasLength(1));
      pending.completeError(StateError('network failure'));
      await tester.pumpAndSettle();
      expect(controller.saving, isFalse);
      expect(controller.value!.name, service.name);
      expect(find.byKey(const ValueKey('document-title-saving')), findsNothing);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.text('头部保存失败，请重试'), findsWidgets);
      service.pending = null;
      await tester.tap(find.byKey(const ValueKey('document-title-edit')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('document-title-input')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('document-title-input')),
        '重新保存',
      );
      await tester.tap(find.byKey(const ValueKey('document-header-submit')));
      await tester.pumpAndSettle();
      expect(controller.value!.name, '重新保存');
      expect(service.patches, hasLength(2));
      expect(find.byKey(const ValueKey('document-title-saving')), findsNothing);
    },
  );

  testWidgets(
    'permission loss during an open title sheet prevents submission',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('document-title-edit')));
      await tester.pumpAndSettle();
      service.editable = false;
      await controller.refresh();
      await tester.enterText(
        find.byKey(const ValueKey('document-title-input')),
        '过期输入',
      );
      await tester.tap(find.byKey(const ValueKey('document-header-submit')));
      await tester.pumpAndSettle();
      expect(service.patches, isEmpty);
      expect(controller.value!.name, '桌面文档标题');
    },
  );
}
