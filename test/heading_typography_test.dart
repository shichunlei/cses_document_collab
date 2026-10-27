import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/controller/collab_controller.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collaborative_editor_page.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/heading_typography_oracle.dart';

/// 用完整页面的 RenderParagraph 验证发布版字号，不绕过页面文字装饰。
void main() => registerHeadingTypographyTests();

/// 注册完整页面字号回归，期望数据随测试编译，不读取宿主文件路径。
/// [useDeviceViewport] 默认 false 使用固定测试画布；真机传 true，保留设备实际视口与移动选区服务。
void registerHeadingTypographyTests({bool useDeviceViewport = false}) {
  final oracle =
      jsonDecode(headingTypographyOracleJson) as Map<String, dynamic>;
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(0.0),
          ),
        );
  });
  for (final alignment in [
    'left',
    'center',
    'right',
    'justify',
    'distributed',
  ]) {
    for (final type in ['heading_3', 'paragraph', 'quote']) {
      testWidgets(
        'text depth $alignment $type uses published 32px layout steps',
        (tester) async {
          final size = type == 'heading_3' ? 25.6 : 16.0;
          await _verifyPage(
            tester,
            [
              for (final (index, depth) in [0, 1, 2, 0].indexed)
                CollabEditorBlock(
                  id: 'depth$index',
                  blockType: type,
                  text: '缩进',
                  alignment: alignment,
                  paragraphStyle: CollabResource.fromValues({'depth': depth}),
                ),
            ],
            List.generate(4, (_) => [size, size]),
            useDeviceViewport: useDeviceViewport,
            expectedIndents: [0, 32, 64, 0],
          );
        },
      );
    }
    testWidgets('final heading sizes $alignment follow published defaults', (
      tester,
    ) async {
      final defaults = oracle['defaults'] as List;
      await _verifyPage(
        tester,
        [
          for (final item in defaults)
            CollabEditorBlock(
              id: 'h${item['level']}',
              blockType: 'heading_${item['level']}',
              text: '标题${item['level']}',
              alignment: alignment,
            ),
          CollabEditorBlock(
            id: 'body',
            blockType: 'paragraph',
            text: '正文',
            alignment: alignment,
          ),
        ],
        [
          for (final item in defaults)
            List<double>.filled(
              '标题${item['level']}'.length,
              (item['expected'] as num).toDouble(),
            ),
          [16, 16],
        ],
        useDeviceViewport: useDeviceViewport,
      );
    });
    testWidgets('final heading sizes $alignment preserve mixed run overrides', (
      tester,
    ) async {
      final cases = oracle['mixed'] as List;
      await _verifyPage(
        tester,
        [
          for (var i = 0; i < cases.length; i++)
            CollabEditorBlock(
              id: 'mixed$i',
              blockType: cases[i]['type'] as String,
              text: (cases[i]['runs'] as List).map((run) => run['text']).join(),
              alignment: alignment,
              paragraphStyle: CollabResource.fromValues(
                Map<String, dynamic>.from(cases[i]['props'] as Map),
              ),
              segments: [
                for (final run in cases[i]['runs'] as List)
                  CollabEditorTextSegment(
                    text: run['text'] as String,
                    typography: jsonEncode(run['attrs']),
                    href: run['href'] as String?,
                  ),
              ],
            ),
        ],
        [
          for (final item in cases)
            [
              for (final value in item['expected'] as List)
                (value as num).toDouble(),
            ],
        ],
        wraps: true,
        useDeviceViewport: useDeviceViewport,
      );
    });
    testWidgets('legacy font sizes $alignment follow published parsing', (
      tester,
    ) async {
      final cases = oracle['legacy'] as List;
      await _verifyPage(
        tester,
        [
          for (var i = 0; i < cases.length; i++)
            CollabEditorBlock(
              id: 'legacy$i',
              blockType: cases[i]['type'] as String,
              text: (cases[i]['runs'] as List).map((run) => run['text']).join(),
              alignment: alignment,
              paragraphStyle: CollabResource.fromValues(
                Map<String, dynamic>.from(cases[i]['props'] as Map),
              ),
              segments: [
                for (final run in cases[i]['runs'] as List)
                  CollabEditorTextSegment(
                    text: run['text'] as String,
                    typography: jsonEncode(run['attrs']),
                  ),
              ],
            ),
        ],
        [
          for (final item in cases)
            [
              for (final value in item['expected'] as List)
                (value as num).toDouble(),
            ],
        ],
        useDeviceViewport: useDeviceViewport,
      );
    });
    testWidgets(
      'empty heading sizes $alignment match placeholders and defaults',
      (tester) async {
        final cases = oracle['empty'] as List;
        await _verifyPage(
          tester,
          [
            for (var i = 0; i < cases.length; i++)
              CollabEditorBlock(
                id: 'empty$i',
                blockType: cases[i]['type'] as String,
                text: '',
                alignment: alignment,
                paragraphStyle: CollabResource.fromValues(
                  Map<String, dynamic>.from(cases[i]['props'] as Map),
                ),
              ),
          ],
          [
            for (final item in cases) [(item['expected'] as num).toDouble()],
          ],
          placeholders: true,
          useDeviceViewport: useDeviceViewport,
        );
      },
    );
  }
}

/// 挂载借用 [tester] 的完整页面，核对 [blocks] 在编辑/预览/再编辑中的 [expected] 字号。
/// [placeholders] 为 true 时验证空段落占位文字样式；[wraps] 要求每块实际跨行排版。
/// [useDeviceViewport] 为 true 时保留真机实际视口，并检查移动选择服务已挂载。
/// [expectedIndents] 指定各段相对首段的左侧缩进；同字体文本按对齐锚点验证位置及剩余宽度。
/// 测试拥有并释放适配器及宿主。
Future<void> _verifyPage(
  WidgetTester tester,
  List<CollabEditorBlock> blocks,
  List<List<double>> expected, {
  bool placeholders = false,
  bool wraps = false,
  bool useDeviceViewport = false,
  List<double>? expectedIndents,
}) async {
  if (!useDeviceViewport) {
    await tester.binding.setSurfaceSize(const Size(390, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }
  final changes = <List<CollabEditorBlock>>[];
  final adapter = AppFlowyBlockEditorAdapter(
    initialBlocks: blocks,
    onLocalBlocksChanged: changes.add,
  );
  addTearDown(adapter.dispose);
  final controller = _HeadingController(adapter.editorState);
  addTearDown(controller.dispose);
  final before = adapter.editorState.document.toJson();
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        AppFlowyEditorLocalizations.delegate,
      ],
      home: CollaborativeEditorPage(collab: controller),
    ),
  );
  await tester.pumpAndSettle();
  if (useDeviceViewport) {
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget.runtimeType.toString() == 'MobileSelectionServiceWidget',
      ),
      findsOneWidget,
    );
  }
  for (var mode = 0; mode < 3; mode++) {
    RenderParagraph? firstParagraph;
    for (var i = 0; i < blocks.length; i++) {
      final paragraph = _expectRenderedSizes(
        tester,
        adapter.editorState.document.nodeAtPath([i])!,
        expected[i],
        placeholder: placeholders,
      );
      firstParagraph ??= paragraph;
      if (expectedIndents != null) {
        expect(
          paragraph.localToGlobal(Offset.zero).dx -
              firstParagraph.localToGlobal(Offset.zero).dx,
          closeTo(
            expectedIndents[i] *
                switch (blocks[i].alignment) {
                  'center' => .5,
                  'right' => 0,
                  _ => 1,
                },
            .001,
          ),
        );
        expect(
          firstParagraph.constraints.maxWidth - paragraph.constraints.maxWidth,
          closeTo(expectedIndents[i], .001),
        );
      }
      if (wraps) {
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: blocks[i].text.length),
        );
        expect(boxes.map((box) => box.top).toSet().length, greaterThan(1));
      }
    }
    expect(adapter.editorState.document.toJson(), before);
    expect(changes, isEmpty);
    expect(tester.takeException(), isNull);
    if (mode < 2) {
      await tester.tap(find.byKey(const ValueKey('editor-mode-toggle')));
      await tester.pumpAndSettle();
    }
  }
  await tester.pumpWidget(const SizedBox.shrink());
}

/// 从借用 [tester] 中 [node] 的实际绘制对象按字符核对 [expected]。
/// [placeholder] 为 true 时检查占位文字，每个字符均应采用单一预期字号。
/// 递归合并父子样式，覆盖分散对齐切片后的嵌套 span 与链接分段。
/// 返回页面拥有的绘制对象，调用方只借用，不释放。
RenderParagraph _expectRenderedSizes(
  WidgetTester tester,
  Node node,
  List<double> expected, {
  required bool placeholder,
}) {
  final rich = find.byWidgetPredicate(
    (widget) => widget is AppFlowyRichText && identical(widget.node, node),
  );
  expect(rich, findsOneWidget);
  final widget = tester.widget<AppFlowyRichText>(rich);
  final text = placeholder ? widget.placeholderText : node.delta!.toPlainText();
  final target = find.descendant(
    of: rich,
    matching: find.byWidgetPredicate(
      (widget) => widget is RichText && widget.text.toPlainText() == text,
    ),
  );
  expect(target, findsOneWidget);
  final paragraph = tester.renderObject<RenderParagraph>(target);
  final sizes = <double>[];

  /// 按 [span] 的父级 [inherited] 字体继承规则收集最终字符字号。
  void collect(InlineSpan span, TextStyle inherited) {
    expect(span, isA<TextSpan>());
    final current = span as TextSpan;
    final style = inherited.merge(current.style);
    for (var i = 0; i < (current.text?.length ?? 0); i++) {
      sizes.add(paragraph.textScaler.scale(style.fontSize!));
      if (node.type == HeadingBlockKeys.type) {
        expect(style.fontWeight, FontWeight.bold);
      }
    }
    for (final child in current.children ?? const <InlineSpan>[]) {
      collect(child, style);
    }
  }

  collect(paragraph.text, const TextStyle());
  final values = placeholder
      ? List<double>.filled(text.length, expected.single)
      : expected;
  expect(sizes.length, values.length);
  for (var i = 0; i < sizes.length; i++) {
    expect(
      sizes[i],
      closeTo(values[i], .000001),
      reason:
          '${node.type} ${node.attributes[HeadingBlockKeys.level]} character $i',
    );
  }
  return paragraph;
}

/// 借用适配器正文的已初始化宿主，不连接网络或原生库。
class _HeadingController extends CollabController {
  /// [state] 由测试适配器拥有和释放。
  _HeadingController(this.state) : super.localDraft(databasePath: '/unused');

  /// 测试适配器拥有的正文状态。
  final EditorState state;

  /// 返回借用正文供真实页面建立文字装饰链。
  @override
  EditorState get editorState => state;

  /// 测试正文已就绪，不执行原生初始化。
  @override
  bool get initialized => true;

  /// 测试允许编辑/预览切换。
  @override
  bool get canEdit => true;

  /// 测试正文无权限或结构锁定。
  @override
  String? get readOnlyReason => null;
}
