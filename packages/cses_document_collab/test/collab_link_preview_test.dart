import 'dart:async';

import 'package:cses_document_collab/src/editor/collab_link_preview.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metalink/metalink.dart';

const _url = 'https://example.test/article';

/// Returns parsed fixture metadata; optional [image] is resolved against [_url].
/// Completes locally without network activity or editor mutation.
Future<ExtractionResult<LinkMetadata>> _metadata({String image = ''}) =>
    MetaLinkParser().parseHtml(
      '<html><head><meta property="og:title" content="网页标题">'
      '<meta property="og:description" content="网页摘要">'
      '<meta property="og:image" content="$image">'
      '</head><body><script>bad()</script></body></html>',
      documentUrl: Uri.parse(_url),
    );

/// Returns a native preview harness with borrowed [load] and saved [props].
/// [url] defaults to the fixture URL, [width] is in logical pixels (default 400),
/// [textScale] defaults to 1 and scales text for accessibility checks.
/// Optional [onOpen] receives taps; null makes navigation a no-op.
Widget _app({
  required CollabLinkPreviewLoader load,
  CollabResource props = const CollabResource(),
  VoidCallback? onOpen,
  String url = _url,
  double width = 400,
  double textScale = 1,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: width,
        child: CollabLinkPreview(
          url: url,
          props: props,
          loadPreview: load,
          onOpen: onOpen ?? () {},
        ),
      ),
    ),
  ),
);

/// Registers local preview fallback, navigation and async lifecycle checks.
void main() {
  testWidgets(
    'network failure retains saved content and retry refreshes metadata',
    (tester) async {
      var calls = 0;
      var opens = 0;
      final props = CollabResource.fromValues({
        'title': '已保存标题',
        'description': '已保存摘要',
      });
      await tester.pumpWidget(
        _app(
          load: (_) {
            if (calls++ == 0) throw StateError('offline');
            return _metadata();
          },
          props: props,
          onOpen: () => opens++,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已保存标题'), findsOneWidget);
      expect(find.text('已保存摘要'), findsOneWidget);
      expect(find.text('预览暂时无法加载'), findsOneWidget);
      await tester.tap(find.text('已保存标题'));
      expect(opens, 1);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('预览暂时无法加载'), findsNothing);
      expect(find.text('已保存标题'), findsOneWidget);
      expect(find.text('网页标题'), findsNothing);
    },
  );

  testWidgets(
    'structured failures retain usable partial metadata and offer retry',
    (tester) async {
      final parsed = await _metadata();
      final failed = ExtractionResult(
        metadata: parsed.metadata,
        diagnostics: parsed.diagnostics,
        errors: const [
          MetaLinkError(code: MetaLinkErrorCode.network, message: 'offline'),
        ],
      );
      await tester.pumpWidget(_app(load: (_) async => failed));
      await tester.pumpAndSettle();
      expect(find.text('网页标题'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    },
  );

  testWidgets(
    'host-only old title allows extracted title; metadata stays local',
    (tester) async {
      final props = CollabResource.fromValues({'title': 'example.test'});
      await tester.pumpWidget(_app(load: (_) => _metadata(), props: props));
      await tester.pumpAndSettle();
      expect(find.text('网页标题'), findsOneWidget);
      expect(find.text('网页摘要'), findsOneWidget);
      expect(props.values, {'title': 'example.test'});
      expect(find.textContaining('bad()'), findsNothing);
    },
  );

  testWidgets('empty metadata remains an openable URL card', (tester) async {
    var opens = 0;
    await tester.pumpWidget(
      _app(
        load: (_) =>
            MetaLinkParser().parseHtml('', documentUrl: Uri.parse(_url)),
        onOpen: () => opens++,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('example.test'), findsOneWidget);
    await tester.tap(find.text(_url));
    expect(opens, 1);
  });

  for (final width in [180.0, 400.0]) {
    testWidgets('thumbnail sits right of text at width $width', (tester) async {
      final cover = await tester.runAsync(() => createTestImage());
      final cache = PaintingBinding.instance.imageCache;
      cache.putIfAbsent(
        const NetworkImage('https://example.test/cover.png'),
        () => OneFrameImageStreamCompleter(
          Future.value(ImageInfo(image: cover!)),
        ),
      );
      await tester.pumpWidget(
        _app(
          load: (_) => _metadata(image: '/cover.png'),
          width: width,
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();
      final thumbnail = tester.getRect(find.byType(RawImage));
      final title = tester.getRect(find.text('网页标题'));
      final description = tester.getRect(find.text('网页摘要'));
      final url = tester.getRect(find.text(_url));
      expect(thumbnail.width, greaterThan(0));
      expect(thumbnail.width, lessThanOrEqualTo(112));
      expect(title.right, lessThan(thumbnail.left));
      expect(description.right, lessThan(thumbnail.left));
      expect(url.right, lessThan(thumbnail.left));
      expect(title.top, lessThan(thumbnail.bottom));
      expect(url.bottom, greaterThan(thumbnail.top));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      cache.clear();
      cache.clearLiveImages();
    });
  }

  testWidgets('image failures and narrow cards keep text readable', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(load: (_) => _metadata(image: '/cover.png'), width: 180),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as NetworkImage).url, 'https://example.test/cover.png');
    expect(image.errorBuilder, isNotNull);
    expect(find.text('网页标题'), findsOneWidget);
    expect(
      tester.renderObject<RenderBox>(find.text('网页标题')).constraints.maxWidth,
      180 - 24,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'prop changes reuse request; late completion after disposal is safe',
    (tester) async {
      final pending = Completer<ExtractionResult<LinkMetadata>>();
      var calls = 0;
      Future<ExtractionResult<LinkMetadata>> load(String _) {
        calls++;
        return pending.future;
      }

      await tester.pumpWidget(_app(load: load));
      await tester.pumpWidget(
        _app(load: load, props: CollabResource.fromValues({'title': '修改标题'})),
      );
      expect(calls, 1);
      expect(find.text('修改标题'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      pending.complete(await _metadata());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
