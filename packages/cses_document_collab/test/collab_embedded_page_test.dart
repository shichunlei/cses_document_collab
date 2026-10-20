import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:cses_document_collab/src/ui/modal/collab_embedded_page.dart';
import 'support/fake_link_web_platform.dart';

/// Bounded frame harness for original [url]; platform state is supplied by the test.
Widget _app(String url) => MaterialApp(
  home: Scaffold(
    body: SizedBox(height: 240, child: CollabEmbeddedPage(url: url)),
  ),
);

/// Verifies frame source selection, navigation, retry and obsolete request isolation.
void main() {
  late WebViewPlatform? old;
  late FakeLinkWebPlatform platform;
  setUp(() {
    old = WebViewPlatform.instance;
    platform = FakeLinkWebPlatform();
    WebViewPlatform.instance = platform;
  });
  tearDown(() {
    WebViewPlatform.instance = old ?? FakeLinkWebPlatform();
  });

  for (final url in [
    'https://example.test/page',
    'https://juejin.cn/post/123',
    'https://www.figma.com/design/demo/Design',
  ]) {
    testWidgets(
      'loads original provider $url, rejects non-web navigation and retries',
      (tester) async {
        await tester.pumpWidget(_app(url));
        await tester.pumpAndSettle();
        expect(platform.loads.single, collabFrameUrl(url));
        expect(find.text('内嵌网页'), findsOneWidget);
        final delegate = platform.controllers.single.delegate!;
        expect(
          await delegate.navigation!(
            const NavigationRequest(url: 'javascript:bad()', isMainFrame: true),
          ),
          NavigationDecision.prevent,
        );
        expect(
          await delegate.navigation!(
            const NavigationRequest(
              url: 'https://example.test/ok',
              isMainFrame: true,
            ),
          ),
          NavigationDecision.navigate,
        );
        delegate.error!(
          const WebResourceError(
            errorCode: -1,
            description: 'subresource',
            isForMainFrame: false,
          ),
        );
        await tester.pump();
        expect(find.text('网页暂时无法加载'), findsNothing);
        delegate.error!(
          const WebResourceError(
            errorCode: -1,
            description: 'offline',
            isForMainFrame: true,
          ),
        );
        await tester.pump();
        expect(find.text('网页暂时无法加载'), findsOneWidget);
        await tester.tap(find.text('重试'));
        await tester.pumpAndSettle();
        expect(platform.loads, [collabFrameUrl(url), collabFrameUrl(url)]);
        delegate.progress?.call(1);
        await tester.pump();
        expect(find.byType(LinearProgressIndicator), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        delegate.error!(
          const WebResourceError(
            errorCode: -1,
            description: 'late',
            isForMainFrame: true,
          ),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('URL replacement and disposal stop delayed initialization', (
    tester,
  ) async {
    platform.scriptGate = Completer<void>();
    await tester.pumpWidget(_app('https://example.test/old'));
    await tester.pump();
    final gate = platform.scriptGate!;
    platform.scriptGate = null;
    await tester.pumpWidget(_app('https://example.test/new'));
    await tester.pumpAndSettle();
    gate.complete();
    await tester.pumpAndSettle();
    expect(platform.loads, [Uri.parse('https://example.test/new')]);
    platform.scriptGate = Completer<void>();
    await tester.pumpWidget(_app('https://example.test/dispose'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    platform.scriptGate!.complete();
    await tester.pumpAndSettle();
    expect(platform.loads.length, 1);
    expect(tester.takeException(), isNull);
  });
}
