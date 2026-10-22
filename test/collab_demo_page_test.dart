import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/demo/collab_demo_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证首页提供独立日记入口，以及协同文档不可用时原离线编辑的完整往返流程。
void main() {
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(0.0),
          ),
        );
  });

  testWidgets('connection page scrolls and exposes the editor route', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        home: CollabDemoPage(localDraft: true),
      ),
    );

    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(find.text('CSES 协同 Demo'), findsOneWidget);
    expect(find.byKey(const ValueKey('open-collaborative-editor')), findsOne);
    expect(find.byKey(const ValueKey('open-offline-image-composer')), findsOne);
    expect(find.byKey(const ValueKey('open-local-journal')), findsOne);
    expect(
      find.byKey(const ValueKey('collaborative-appflowy-editor')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('editor-undo')), findsNothing);
    expect(find.byKey(const ValueKey('editor-redo')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('offline entry works during loading and after storage failure', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final supportPath = Completer<String?>();
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (_) => supportPath.future);
    addTearDown(() => messenger.setMockMethodCallHandler(pathChannel, null));
    try {
      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          home: CollabDemoPage(localDraft: true),
        ),
      );
      final entry = find.byKey(const ValueKey('open-offline-image-composer'));
      expect(find.text('正在加载文档…'), findsOneWidget);
      expect(tester.widget<FilledButton>(entry).onPressed, isNotNull);
      // 重复派发重建前的按钮回调，首页也只打开一个本地会话。
      final open = tester.widget<FilledButton>(entry).onPressed!;
      open();
      open();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('image-composer-editor')),
        findsOneWidget,
      );

      supportPath.complete(null);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('image-composer-back')));
      await _finishRoute(tester);
      expect(find.text('文档加载失败，请检查本地库或登录配置'), findsOneWidget);
      expect(tester.widget<FilledButton>(entry).onPressed, isNotNull);
      final collaborative = find.byKey(
        const ValueKey('open-collaborative-editor'),
      );
      expect(tester.widget<FilledButton>(collaborative).onPressed, isNull);

      await tester.tap(entry);
      await tester.pumpAndSettle();
      final editor = tester.widget<AppFlowyEditor>(
        find.byKey(const ValueKey('image-composer-editor')),
      );
      final state = editor.editorState;
      final transaction = state.transaction
        ..insertText(state.document.root.children.single, 0, '仅保存在本机的文字');
      final edited = state.apply(transaction);
      await tester.pumpAndSettle();
      await edited;
      await tester.tap(
        find.byKey(const ValueKey('image-composer-template-sunset')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('image-composer-preview-toggle')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('image-composer-preview')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('image-composer-generate')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('image-composer-back')));
      await _finishRoute(tester);
      expect(state.isDisposed, isTrue);
      expect(tester.widget<FilledButton>(entry).onPressed, isNotNull);
      expect(tester.widget<FilledButton>(collaborative).onPressed, isNull);
      expect(tester.takeException(), isNull);
    } finally {
      if (!supportPath.isCompleted) supportPath.complete(null);
      await tester.pumpWidget(const SizedBox.shrink());
      tester.testTextInput.unregister();
      await tester.pump();
    }
  });
}

/// 用 [tester] 等待路由退场及本地订阅注销，再刷新宿主的入口状态。
Future<void> _finishRoute(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>(() {}));
  await tester.pumpAndSettle();
}
