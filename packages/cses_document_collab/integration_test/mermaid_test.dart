import 'dart:convert';
import 'dart:io';

import 'package:cses_document_collab/src/editor/collab_mermaid_visual.dart';
import 'package:cses_document_collab/src/model/collab_mermaid_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../test/collab_mermaid_test.dart' as editor_tests;

/// 在Android真机验证正式页面交互和随包离线引擎；只使用隔离测试正文。
/// 测试不初始化账号/协同连接/业务缓存；结束后由宿主覆盖安装普通Demo。
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    expect(Platform.isAndroid, isTrue);
  });
  setUp(binding.testTextInput.register);
  tearDown(binding.testTextInput.unregister);
  editor_tests.main();
  testWidgets(
    'Android bundled WebView renders seven types and five desktop templates, invalid and empty source',
    (tester) async {
      final cases = <String, String>{
        'flowchart TD\nA[开始]-->B[完成]': '开始',
        'sequenceDiagram\nAlice->>Bob: 你好': '你好',
        'classDiagram\nAnimal <|-- Duck': 'Duck',
        'stateDiagram-v2\n[*] --> Active': 'Active',
        'pie\n"甲": 40\n"乙": 60': '甲',
        'gantt\ndateFormat YYYY-MM-DD\nsection 项目\n开发 :2026-10-16, 3d': '开发',
        'mindmap\n  root((中心))\n    分支': '中心',
      };
      for (final entry in cases.entries) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: CollabMermaidVisual(source: entry.key)),
          ),
        );
        await tester.pumpAndSettle();
        await _waitForGraph(tester, entry.value);
      }
      final labels = ['Hello John', 'Start', 'BankAccount', 'Root', 'LinkedIn'];
      for (var i = 0; i < collabMermaidExamples.length; i++) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CollabMermaidVisual(
                source: collabMermaidExamples[i].source,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _waitForGraph(tester, labels[i]);
      }
      final view = tester.widget<WebViewWidget>(find.byType(WebViewWidget));
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CollabMermaidVisual(source: 'this is invalid Mermaid'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.runAsync(() async {
        for (var i = 0; i < 80; i++) {
          final result = await view.platform.params.controller
              .runJavaScriptReturningResult(
                "document.getElementById('error').textContent.length > 0 && document.querySelectorAll('#graph svg').length === 1",
              );
          if (result == true || result == 'true') return;
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        fail('Invalid syntax must preserve the last valid graph');
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: CollabMermaidVisual(source: '')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      final empty = await view.platform.params.controller
          .runJavaScriptReturningResult(
            "document.querySelectorAll('#graph svg').length",
          );
      expect(empty.toString(), '0');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    },
  );
}

/// 在借用 [tester] 的真实平台视图内等待包含 [label] 的SVG，失败时返回页面诊断。
Future<void> _waitForGraph(WidgetTester tester, String label) async {
  final view = tester.widget<WebViewWidget>(find.byType(WebViewWidget));
  await tester.runAsync(() async {
    Object? last;
    for (var i = 0; i < 100; i++) {
      try {
        last = await view.platform.params.controller.runJavaScriptReturningResult(
          "document.querySelectorAll('#graph svg').length === 1 && document.getElementById('graph').textContent.includes(${jsonEncode(label)})",
        );
        if (last == true || last == 'true') return;
      } catch (error) {
        last = error;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    final html = await view.platform.params.controller
        .runJavaScriptReturningResult('document.documentElement.outerHTML');
    fail('Expected rendered diagram $label; status=$last; html=$html');
  });
  await tester.pump();
}
