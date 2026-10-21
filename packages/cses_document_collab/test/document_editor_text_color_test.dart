import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/document_editor_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证共用正文的最终字符颜色，覆盖缺省、局部覆盖、链接及容器继承。
void main() => registerDocumentEditorTextColorTests();

/// 注册文字颜色回归；[useDeviceViewport]为true时使用设备实际视口和平台。
/// [onVerified]在每组颜色和正文不变断言通过后调用，接收借用的tester和稳定场景名，
/// 供设备入口截图；Future完成后才卸载正文，回调失败会使当前测试失败。
void registerDocumentEditorTextColorTests({
  bool useDeviceViewport = false,
  Future<void> Function(WidgetTester tester, String name)? onVerified,
}) {
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('keyboardHeightEventChannel'),
      MockStreamHandler.inline(onListen: (_, events) => events.success(0.0)),
    );
  });
  for (final alignment in ['left', 'distributed']) {
    for (final preview in [false, true]) {
      testWidgets(
        'document colors remain explicit with $alignment alignment, preview=$preview',
        (tester) async {
          if (!useDeviceViewport) {
            await tester.binding.setSurfaceSize(const Size(390, 1200));
            addTearDown(() => tester.binding.setSurfaceSize(null));
          }
          final changes = <List<CollabEditorBlock>>[];
          final adapter = AppFlowyBlockEditorAdapter(
            initialBlocks: [
              CollabEditorBlock(
                id: 'mixed',
                blockType: 'paragraph',
                text: '默认红蓝白链接',
                alignment: alignment,
                segments: const [
                  CollabEditorTextSegment(text: '默认'),
                  CollabEditorTextSegment(text: '红', textColor: '#ff0000'),
                  CollabEditorTextSegment(text: '蓝', textColor: '0xff0000ff'),
                  CollabEditorTextSegment(text: '白', textColor: '#ffffff', backgroundColor: '#333333'),
                  CollabEditorTextSegment(text: '链接', href: 'https://example.com'),
                ],
              ),
              for (final type in ['heading_2', 'quote', 'bulleted_list', 'numbered_list', 'todo_list'])
                CollabEditorBlock(id: type, blockType: type, text: '正文', alignment: alignment),
              const CollabEditorBlock(id: 'callout', blockType: 'callout', text: '', blockTextColor: '#008000'),
              CollabEditorBlock(
                id: 'inside',
                parentId: 'callout',
                blockType: 'paragraph',
                text: '继承覆盖',
                alignment: alignment,
                segments: const [
                  CollabEditorTextSegment(text: '继承'),
                  CollabEditorTextSegment(text: '覆盖', textColor: '#ff0000'),
                ],
              ),
            ],
            onLocalBlocksChanged: changes.add,
          );
          final state = adapter.editorState;
          final before = state.document.toJson();
          try {
            await tester.pumpWidget(
              MaterialApp(
                localizationsDelegates: const [
                  GlobalMaterialLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  AppFlowyEditorLocalizations.delegate,
                ],
                home: Scaffold(
                  backgroundColor: Colors.white,
                  appBar: useDeviceViewport ? AppBar(title: Text('文字颜色验收：${preview ? '预览' : '编辑'}')) : null,
                  body: SafeArea(
                    child: DocumentEditorView(editorState: state, preview: preview, editable: !preview),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            _expectColors(tester, state.document.nodeAtPath([0])!, const [
              Colors.black,
              Colors.black,
              Color(0xffff0000),
              Color(0xff0000ff),
              Colors.white,
              Colors.lightBlue,
              Colors.lightBlue,
            ]);
            for (var index = 1; index <= 5; index++) {
              _expectColors(tester, state.document.nodeAtPath([index])!, const [Colors.black, Colors.black]);
            }
            _expectColors(tester, state.document.nodeAtPath([6, 0])!, const [
              Color(0xff008000),
              Color(0xff008000),
              Color(0xffff0000),
              Color(0xffff0000),
            ]);
            expect(state.document.toJson(), before);
            expect(changes, isEmpty);
            expect(tester.takeException(), isNull);
            if (onVerified != null) {
              await onVerified(tester, '$alignment-${preview ? 'preview' : 'edit'}');
            }
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            adapter.dispose();
          }
        },
        variant: useDeviceViewport
            ? const DefaultTestVariant()
            : TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
      );
    }
  }
}

/// 在借用的[tester]中按UTF-16字符核对[node]最终绘制样式与[expected]颜色。
/// 递归合并父子样式，确保分散对齐和链接装饰后的颜色仍遵循继承规则。
void _expectColors(WidgetTester tester, Node node, List<Color> expected) {
  final rich = find.byWidgetPredicate((widget) => widget is AppFlowyRichText && identical(widget.node, node));
  final target = find.descendant(
    of: rich,
    matching: find.byWidgetPredicate(
      (widget) => widget is RichText && widget.text.toPlainText() == node.delta!.toPlainText(),
    ),
  );
  expect(target, findsOneWidget);
  final paragraph = tester.renderObject<RenderParagraph>(target);
  final actual = <Color?>[];

  /// 将[span]与父级[inherited]样式合并，收集实际正文字符的颜色。
  void collect(InlineSpan span, TextStyle inherited) {
    final current = span as TextSpan;
    final style = inherited.merge(current.style);
    actual.addAll(List<Color?>.filled(current.text?.length ?? 0, style.color));
    for (final child in current.children ?? const <InlineSpan>[]) {
      collect(child, style);
    }
  }

  collect(paragraph.text, const TextStyle());
  expect(actual, expected, reason: '${node.type}: ${node.delta!.toPlainText()}');
}
