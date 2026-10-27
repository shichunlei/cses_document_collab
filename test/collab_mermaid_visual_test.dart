import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:cses_document_collab/src/ui/modal/collab_mermaid_visual.dart';

/// 验证离线来源、注入边界、去抖、重试及关闭后的异步失效。
void main() {
  late _Platform platform;
  WebViewPlatform? previous;
  setUp(() {
    previous = WebViewPlatform.instance;
    platform = _Platform();
    WebViewPlatform.instance = platform;
  });
  tearDown(() {
    WebViewPlatform.instance = previous ?? _Platform();
  });
  testWidgets(
    'offline asset, JSON source and latest-only debounced rendering',
    (tester) async {
      const injection = 'flowchart LR\nA["引号\\" ");evil();//"]-->B';
      await tester.pumpWidget(_app(injection));
      await tester.pumpAndSettle();
      final controller = platform.controllers.single;
      expect(
        controller.assets.single,
        'packages/cses_document_collab/assets/mermaid/index.html',
      );
      expect(
        controller.scripts.last,
        'window.renderDiagram(${jsonEncode(injection)}, 1);',
      );
      expect(
        await controller.navigation!.request!(
          const NavigationRequest(url: 'https://evil.test', isMainFrame: true),
        ),
        NavigationDecision.prevent,
      );
      expect(
        await controller.navigation!.request!(
          const NavigationRequest(url: 'javascript:evil()', isMainFrame: true),
        ),
        NavigationDecision.prevent,
      );
      await tester.pumpWidget(_app('flowchart LR\nA-->C'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(_app('flowchart LR\nA-->D'));
      await tester.pump(const Duration(milliseconds: 349));
      expect(
        controller.scripts
            .where((s) => s.startsWith('window.renderDiagram'))
            .length,
        1,
      );
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(controller.scripts.last, contains('A-->D'));
      expect(platform.controllers.length, 1);
      controller.channel!.onMessageReceived(
        const JavaScriptMessage(message: '{"generation":1,"failed":true}'),
      );
      await tester.pump();
      expect(find.text('语法暂时无法绘制，源码仍可编辑和保存'), findsNothing);
      await tester.pumpWidget(_app(''));
      await tester.pump();
      expect(controller.scripts.last, contains('true'));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'retry replaces controller and old callbacks cannot affect new view',
    (tester) async {
      await tester.pumpWidget(_app('flowchart LR\nA-->B'));
      await tester.pumpAndSettle();
      final old = platform.controllers.single;
      old.navigation!.error!(
        const WebResourceError(
          errorCode: -1,
          description: 'failed',
          isForMainFrame: true,
        ),
      );
      await tester.pump();
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(platform.controllers.length, 2);
      old.navigation!.error!(
        const WebResourceError(
          errorCode: -1,
          description: 'late',
          isForMainFrame: true,
        ),
      );
      old.channel!.onMessageReceived(
        const JavaScriptMessage(message: '{"generation":2,"failed":true}'),
      );
      await tester.pump();
      expect(find.text('绘图组件加载失败，请重试'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      old.navigation!.finished?.call('file:///old');
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'disposal during setup stops asset load and factory failure is visible',
    (tester) async {
      final gate = Completer<void>();
      platform.gate = gate.future;
      await tester.pumpWidget(_app('draft'));
      await tester.pump();
      final old = platform.controllers.single;
      await tester.pumpWidget(const SizedBox.shrink());
      gate.complete();
      await tester.pumpAndSettle();
      expect(old.assets, isEmpty);
      expect(tester.takeException(), isNull);
      platform.failFactory = true;
      await tester.pumpWidget(_app('draft'));
      await tester.pumpAndSettle();
      expect(find.text('绘图组件加载失败，请重试'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}

/// 在借用 [source] 上挂载限高预览。
Widget _app(String source) => MaterialApp(
  home: Scaffold(body: CollabMermaidVisual(source: source)),
);

/// 无网络、无原生资源的平台替身，由用例持有。
class _Platform extends WebViewPlatform {
  final controllers = <_Controller>[];
  Future<void>? gate;
  bool failFactory = false;

  /// 使用 [params] 创建记录控制器，按用例设定延迟或失败。
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    if (failFactory) throw StateError('unavailable');
    final controller = _Controller(params, gate);
    controllers.add(controller);
    return controller;
  }

  /// 为 [params] 创建回调容器。
  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _Navigation(params);

  /// 为 [params] 创建无平台资源的展示替身。
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _View(params);
}

/// 记录离线加载与脚本，初始化可以由用例暂停。
class _Controller extends PlatformWebViewController {
  /// [params] 为平台参数，[gate] 为可选初始化屏障。
  _Controller(super.params, this.gate) : super.implementation();
  final Future<void>? gate;
  final assets = <String>[];
  final scripts = <String>[];
  _Navigation? navigation;
  JavaScriptChannelParams? channel;

  /// 配置 [mode] 时等待屏障。
  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {
    await gate;
  }

  /// 借用 [params] 保存本地状态桥回调。
  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    channel = params;
  }

  /// 借用 [delegate] 保存导航回调。
  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate delegate,
  ) async {
    navigation = delegate as _Navigation;
  }

  /// 记录 [key] 并模拟离线页面完成。
  @override
  Future<void> loadFlutterAsset(String key) async {
    assets.add(key);
    navigation!.finished?.call('file:///$key');
  }

  /// 记录 [script]，不执行代码或网络请求。
  @override
  Future<void> runJavaScript(String script) async {
    scripts.add(script);
  }
}

/// 公开给用例驱动的回调容器。
class _Navigation extends PlatformNavigationDelegate {
  /// [params] 为创建参数。
  _Navigation(super.params) : super.implementation();
  NavigationRequestCallback? request;
  PageEventCallback? finished;
  WebResourceErrorCallback? error;

  /// 保存导航 [callback]。
  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async {
    request = callback;
  }

  /// 保存完成 [callback]。
  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async {
    finished = callback;
  }

  /// 保存失败 [callback]。
  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async {
    error = callback;
  }
}

/// 平台视图替身。
class _View extends PlatformWebViewWidget {
  /// [params] 为借用的平台参数。
  _View(super.params) : super.implementation();

  /// 在借用 [context] 中展示固定文字。
  @override
  Widget build(BuildContext context) => const Text('本地绘图');
}
