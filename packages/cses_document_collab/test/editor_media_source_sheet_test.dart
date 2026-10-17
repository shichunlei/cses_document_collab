import 'dart:async';

import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/editor_media_upload.dart';
import 'package:cses_document_collab/src/editor/editor_media_source_sheet.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/document_cover_catalog.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

const _image = EditorLocalFile(
  path: '/tmp/photo.png',
  name: '照片.png',
  size: 1024,
  mimeType: 'image/png',
);

class _Upload extends EditorMediaUploadService {
  EditorLocalFile? selected = _image;
  int calls = 0;
  bool fail = false;
  Completer<EditorMediaSource>? pending;
  CancelToken? token;
  @override
  Future<EditorLocalFile?> pickFile(String kind) async => selected;
  @override
  Future<EditorMediaSource> upload(
    EditorLocalFile file,
    String kind, {
    required CancelToken cancelToken,
    required void Function(double) onProgress,
  }) async {
    calls++;
    token = cancelToken;
    onProgress(.5);
    if (fail) throw const FormatException('上传失败，请重试');
    return pending != null
        ? pending!.future
        : EditorMediaSource('https://example.test/uploaded.png', file: file);
  }
}

void main() {
  test(
    'SVG upload is supported for document icons while body images keep their format boundary',
    () {
      const file = EditorLocalFile(
        path: '/tmp/icon.svg',
        name: '图标.svg',
        size: 100,
        mimeType: 'image/svg+xml',
      );
      expect(validateEditorMediaFile('document_icon', file), isNull);
      expect(editorMediaMaxBytes('document_icon'), 60 * 1024 * 1024);
      expect(validateEditorMediaFile('image', file), isNotNull);
      expect(validateEditorMediaFile('document_banner', file), isNotNull);
    },
  );

  Future<void> open(
    WidgetTester tester,
    _Upload? service, {
    String kind = 'image',
    void Function(EditorMediaSource?)? onResult,
    bool Function()? canEdit,
    double textScale = 1,
    double keyboardInset = 0,
    bool allowRemove = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            viewInsets: EdgeInsets.only(bottom: keyboardInset),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final result = await showEditorMediaSourceSheet(
                  context,
                  blockType: kind,
                  service: service,
                  canEdit: canEdit,
                  allowRemove: allowRemove,
                );
                onResult?.call(result);
              },
              child: const Text('添加'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'source sheet has tabs and preserves a link while changing source',
    (tester) async {
      final service = _Upload();
      EditorMediaSource? result;
      await open(tester, service, onResult: (value) => result = value);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('editor-url-block-input')),
        'https://example.test/photo.png',
      );
      await tester.tap(find.byKey(const ValueKey('editor-media-upload-tab')));
      await tester.pumpAndSettle();
      expect(find.text('点击选择图片文件'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('editor-media-link-tab')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('editor-url-block-input')),
            )
            .controller!
            .text,
        'https://example.test/photo.png',
      );
      await tester.tap(find.byKey(const ValueKey('editor-url-block-submit')));
      await tester.pumpAndSettle();
      expect(result!.url, 'https://example.test/photo.png');
      expect(service.calls, 0);
    },
  );

  testWidgets(
    'cover gallery uses desktop groups and preview URLs but selects the original URL',
    (tester) async {
      final upload = _Upload();
      EditorMediaSource? result;
      await open(
        tester,
        upload,
        kind: 'document_banner',
        onResult: (value) => result = value,
      );
      expect(find.text('公共图库'), findsOneWidget);
      expect(find.text('上传图片'), findsOneWidget);
      expect(find.text('图片链接'), findsOneWidget);
      expect(find.text('太空'), findsOneWidget);
      expect(find.text('油画'), findsOneWidget);
      expect(find.text('创意'), findsOneWidget);
      final images = documentCoverGroups
          .expand((group) => group.items)
          .toList();
      expect(images, hasLength(20));
      final tile = find.byKey(ValueKey('document-cover-${images.first.id}'));
      final preview = tester.widget<Image>(
        find.descendant(of: tile, matching: find.byType(Image)),
      );
      expect((preview.image as NetworkImage).url, images.first.previewUrl);
      await tester.pumpAndSettle();
      // Flutter's test HTTP client rejects thumbnail requests. A failed preview
      // must still allow choosing the stable original URL.
      expect(
        find.descendant(of: tile, matching: find.byIcon(LucideIcons.image)),
        findsOneWidget,
      );
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(result!.url, images.first.url);
      expect(result!.url, isNot(images.first.previewUrl));
      expect(upload.calls, 0);
      expect(find.byType(BottomSheet), findsNothing);
    },
  );

  for (final setting in [
    (const Size(390, 844), 1.0),
    (const Size(320, 640), 1.5),
  ]) {
    testWidgets(
      'gallery scroll keeps header, tabs and remove action fixed: ${setting.$1}',
      (tester) async {
        await tester.binding.setSurfaceSize(setting.$1);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        EditorMediaSource? result;
        await open(
          tester,
          _Upload(),
          kind: 'document_banner',
          allowRemove: true,
          textScale: setting.$2,
          onResult: (value) => result = value,
        );
        final header = find.byKey(
          const ValueKey('document-cover-source-header'),
        );
        final fixedKeys = [
          'document-cover-source-header',
          'editor-media-source-close',
          'document-cover-library-tab',
          'editor-media-upload-tab',
          'editor-media-link-tab',
          'editor-cover-url-remove',
        ];
        final bounds = {
          for (final key in fixedKeys)
            key: tester.getRect(find.byKey(ValueKey(key))),
        };
        final first = find.byKey(
          const ValueKey('document-cover-space-telescope-1'),
        );
        final firstTop = tester.getTopLeft(first).dy;
        final scroll = find.byKey(
          const ValueKey('editor-document_banner-source-sheet'),
        );
        expect(find.descendant(of: scroll, matching: header), findsNothing);
        await tester.drag(scroll, const Offset(0, -300));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(first).dy, lessThan(firstTop));
        final image = documentCoverGroups.last.items.last;
        final last = find.byKey(ValueKey('document-cover-${image.id}'));
        await tester.ensureVisible(last);
        await tester.pumpAndSettle();
        for (final entry in bounds.entries) {
          expect(tester.getRect(find.byKey(ValueKey(entry.key))), entry.value);
        }
        // Switch directly from the scrolled gallery. The link form must start
        // at the top and remain reachable without scrolling the fixed header.
        await tester.tap(find.byKey(const ValueKey('editor-media-link-tab')));
        await tester.pumpAndSettle();
        final input = find.byKey(const ValueKey('editor-url-block-input'));
        expect(
          tester
              .getRect(
                find.ancestor(
                  of: input,
                  matching: find.byType(CollabModalField),
                ),
              )
              .top,
          closeTo(tester.getRect(header).bottom, .1),
        );
        const url = 'https://example.test/cover.png';
        await tester.enterText(input, url);
        await tester.tap(
          find.byKey(const ValueKey('document-cover-library-tab')),
        );
        await tester.pumpAndSettle();
        for (final entry in bounds.entries) {
          expect(tester.getRect(find.byKey(ValueKey(entry.key))), entry.value);
        }
        await tester.ensureVisible(last);
        await tester.pumpAndSettle();
        await tester.tap(last);
        await tester.pumpAndSettle();
        expect(result!.url, image.url);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'cover tabs preserve a link and selected file across gallery switches',
    (tester) async {
      final upload = _Upload();
      EditorMediaSource? result;
      await open(
        tester,
        upload,
        kind: 'document_banner',
        onResult: (value) => result = value,
      );
      await tester.tap(find.byKey(const ValueKey('editor-media-link-tab')));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('editor-url-block-input'));
      const url = 'https://example.test/cover.png';
      await tester.enterText(input, url);
      await tester.tap(find.byKey(const ValueKey('editor-media-upload-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-media-pick-file')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('document-cover-library-tab')),
      );
      await tester.pumpAndSettle();
      expect(find.text('太空'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('editor-media-link-tab')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, url);
      await tester.tap(find.byKey(const ValueKey('editor-media-upload-tab')));
      await tester.pumpAndSettle();
      expect(find.text('照片.png'), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(result, isNull);
      await tester.tap(find.byKey(const ValueKey('editor-url-block-submit')));
      await tester.pumpAndSettle();
      expect(result!.url, 'https://example.test/uploaded.png');
      expect(upload.calls, 1);
    },
  );

  testWidgets(
    'readonly during gallery selection leaves the sheet open without a result',
    (tester) async {
      var editable = true;
      var returned = false;
      await open(
        tester,
        _Upload(),
        kind: 'document_banner',
        canEdit: () => editable,
        onResult: (_) => returned = true,
      );
      editable = false;
      await tester.tap(
        find.byKey(const ValueKey('document-cover-space-telescope-1')),
      );
      await tester.pumpAndSettle();
      expect(returned, isFalse);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('文档已进入只读，请关闭面板后重新查看'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('editor-media-source-close')));
      await tester.pumpAndSettle();
      expect(returned, isTrue);
    },
  );

  testWidgets(
    'cover gallery is scrollable on a narrow screen without an upload service',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      EditorMediaSource? result;
      await open(
        tester,
        null,
        kind: 'document_banner',
        textScale: 1.5,
        keyboardInset: 250,
        onResult: (value) => result = value,
      );
      await tester.tap(find.byKey(const ValueKey('editor-media-upload-tab')));
      await tester.pumpAndSettle();
      expect(find.text('当前环境暂不支持图片上传，请使用图库或链接'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('editor-url-block-submit')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(
        find.byKey(const ValueKey('document-cover-library-tab')),
      );
      await tester.pumpAndSettle();
      final image = documentCoverGroups.last.items.last;
      final tile = find.byKey(ValueKey('document-cover-${image.id}'));
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(result!.url, image.url);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('upload keeps file metadata and can retry a failed request', (
    tester,
  ) async {
    final service = _Upload()..fail = true;
    EditorMediaSource? result;
    await open(tester, service, onResult: (value) => result = value);
    await tester.tap(find.byKey(const ValueKey('editor-media-upload-tab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-media-pick-file')));
    await tester.pumpAndSettle();
    expect(find.text('照片.png'), findsOneWidget);
    expect(service.calls, 0);
    await tester.tap(find.byKey(const ValueKey('editor-url-block-submit')));
    await tester.pumpAndSettle();
    expect(find.text('上传失败，请重试'), findsOneWidget);
    expect(result, isNull);
    service.fail = false;
    await tester.tap(find.byKey(const ValueKey('editor-url-block-submit')));
    await tester.pumpAndSettle();
    expect(service.calls, 2);
    expect(result!.file!.name, '照片.png');
    expect(result!.url, startsWith('https://'));
  });

  testWidgets('closing during upload cancels it and ignores the late result', (
    tester,
  ) async {
    final service = _Upload()..pending = Completer<EditorMediaSource>();
    EditorMediaSource? result;
    await open(tester, service, onResult: (value) => result = value);
    await tester.tap(find.byKey(const ValueKey('editor-media-upload-tab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-media-pick-file')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-url-block-submit')));
    await tester.pump();
    expect(find.text('正在上传 50%'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('editor-media-source-close')));
    await tester.pumpAndSettle();
    expect(service.token!.isCancelled, isTrue);
    service.pending!.complete(
      const EditorMediaSource('https://example.test/late.png', file: _image),
    );
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('readonly arriving during upload prevents insertion', (
    tester,
  ) async {
    final service = _Upload()..pending = Completer<EditorMediaSource>();
    var editable = true;
    EditorMediaSource? result;
    await open(
      tester,
      service,
      canEdit: () => editable,
      onResult: (value) => result = value,
    );
    await tester.tap(find.byKey(const ValueKey('editor-media-upload-tab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-media-pick-file')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-url-block-submit')));
    await tester.pump();
    editable = false;
    service.pending!.complete(
      const EditorMediaSource('https://example.test/late.png', file: _image),
    );
    await tester.pumpAndSettle();
    expect(find.text('文档已进入只读，请关闭面板后重新查看'), findsOneWidget);
    expect(result, isNull);
    await tester.tap(find.byKey(const ValueKey('editor-media-source-close')));
    await tester.pumpAndSettle();
  });

  testWidgets('oversized file is rejected before an upload request', (
    tester,
  ) async {
    final service = _Upload()
      ..selected = const EditorLocalFile(
        path: '/tmp/large.png',
        name: 'large.png',
        size: 61 * 1024 * 1024,
        mimeType: 'image/png',
      );
    await open(tester, service);
    await tester.tap(find.byKey(const ValueKey('editor-media-upload-tab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-media-pick-file')));
    await tester.pumpAndSettle();
    expect(find.text('文件过大，不能超过 60 MB'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('editor-url-block-submit')),
          )
          .onPressed,
      isNull,
    );
    expect(service.calls, 0);
    await tester.tap(find.byKey(const ValueKey('editor-media-source-close')));
    await tester.pumpAndSettle();
  });

  for (final kind in [
    'video',
    'audio',
    'attachment',
    'document_banner',
    'document_icon',
  ]) {
    testWidgets('$kind supports local selection in a bottom sheet', (
      tester,
    ) async {
      await open(tester, _Upload(), kind: kind);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.byKey(const ValueKey('editor-media-upload-tab')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('editor-media-source-close')));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('web-only resources keep a link-only bottom sheet', (
    tester,
  ) async {
    await open(tester, _Upload(), kind: 'bookmark');
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-media-upload-tab')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('editor-media-source-close')));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'narrow screen with keyboard and large text keeps actions reachable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await open(tester, _Upload(), textScale: 1.4, keyboardInset: 300);
      await tester.enterText(
        find.byKey(const ValueKey('editor-url-block-input')),
        'https://example.test/image.png',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('editor-url-block-submit')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );

  test('media insertion inside a callout preserves its parent', () async {
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [
        CollabEditorBlock(
          id: 'callout',
          blockType: csesCalloutBlockType,
          text: '',
        ),
        CollabEditorBlock(
          id: 'body',
          parentId: 'callout',
          blockType: 'paragraph',
          text: '正文',
        ),
      ],
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);
    final selection = await applyUrlBlockShortcut(
      adapter.editorState,
      Selection.single(path: [0, 0], startOffset: 2),
      'image',
      'https://example.test/image.png',
    );
    expect(selection!.start.path, [0, 2]);
    expect(adapter.editorState.document.root.children, hasLength(1));
    expect(
      adapter.blocks.where((b) => b.blockType == 'image').single.parentId,
      'callout',
    );
  });

  test(
    'uploaded attachment metadata enters the normal collaborative transaction',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(id: 'body', blockType: 'paragraph', text: ''),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      const file = EditorLocalFile(
        path: '/tmp/report.pdf',
        name: '方案.pdf',
        size: 2048,
        mimeType: 'application/pdf',
      );
      await applyUrlBlockShortcut(
        adapter.editorState,
        Selection.single(path: [0], startOffset: 0),
        'attachment',
        'https://example.test/report.pdf',
        mediaSource: const EditorMediaSource(
          'https://example.test/report.pdf',
          file: file,
        ),
      );
      final resource = changes.single.first.resource!;
      expect(changes.single.first.id, isNot('body'));
      expect(
        changes.single.first.replacesId,
        isNull,
        reason:
            'an upload replaces the empty paragraph with a new resource; '
            'a conversion would discard its initial metadata in Rust',
      );
      expect(resource.string('name'), '方案.pdf');
      expect(resource.number('size'), 2048);
      expect(resource.string('type'), 'application/pdf');
      expect(changes.single.first.text, 'https://example.test/report.pdf');
    },
  );
}
