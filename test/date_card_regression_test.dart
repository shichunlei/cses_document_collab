import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/blockcraft_json_codec.dart';
import 'package:cses_document_collab/src/editor/collab_date_card_settings.dart';
import 'package:cses_document_collab/src/editor/core/document_editor_controller.dart';
import 'package:cses_document_collab/src/model/collab_date_card.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/ui/modal/collab_date_card_visual.dart';
import 'package:cses_document_collab/src/ui/modal/collab_bottom_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'date_card_settings_test_utils.dart';

/// 日期设置尺寸/字号与不可信边框的正式回归，保留审查中的正确行为断言。
void main() {
  setUpAll(() async {
    const font = String.fromEnvironment('DATE_SETTINGS_PREVIEW_FONT');
    if (font.isEmpty) return;
    await (FontLoader('DateSettingsPreview')..addFont(File(font).readAsBytes().then(ByteData.sublistView))).load();
    await (FontLoader(
      'packages/lucide_icons_flutter/Lucide',
    )..addFont(rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'))).load();
  });

  test('border fallback preserves raw data and content scale remains finite', () {
    for (final sample in [
      ('1e-320px dotted', '0px solid'),
      ('0.000001px dashed', '0px solid'),
      ('10000px dotted', '0px solid'),
      ('2px', '2px solid'),
      ('3px double', '3px double'),
    ]) {
      final raw = <String, dynamic>{'bw': sample.$1};
      expect(CollabDateCard(raw).border, sample.$2);
      expect(raw['bw'], sample.$1);
    }
    expect(CollabDateCard({'width': 336}).contentScale, 2);
    expect(CollabDateCard({'width': double.minPositive}).contentScale, 1);
    expect(CollabDateCard({'width': double.infinity}).contentScale, 1);
  });

  testWidgets('cycling back to the current style preserves a desktop-resized card', (tester) async {
    final adapter = _resizedAdapter();
    try {
      await _openSettings(tester, adapter.editorState);
      await tester.tap(find.byKey(const ValueKey('date-card-style-next')));
      await tester.tap(find.byKey(const ValueKey('date-card-style-previous')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('date-card-apply')));
      await tester.pumpAndSettle();
      final values = adapter.blocks.first.resource!.values;
      debugPrint('RESELECT_STYLE_RESULT=$values');
      expect(values['width'], 336.0, reason: '点击已选样式不应抹掉作者的2倍缩放');
      expect(values['height'], 289.504);
      expect(adapter.editorState.undoManager.undoStack.isEmpty, isTrue);
    } finally {
      await tester.pumpWidget(const SizedBox());
      adapter.dispose();
    }
  });

  testWidgets('returning to the original style keeps original geometry and empty history', (tester) async {
    final adapter = _resizedAdapter();
    try {
      await _openSettings(tester, adapter.editorState);
      for (final style in ['square', 'calendar']) {
        await chooseDateCardStyle(tester, style);
      }
      await tester.tap(find.byKey(const ValueKey('date-card-apply')));
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.resource!.values['width'], 336);
      expect(adapter.blocks.first.resource!.values['height'], 289.504);
      expect(adapter.editorState.undoManager.undoStack.isEmpty, isTrue);
    } finally {
      await tester.pumpWidget(const SizedBox());
      adapter.dispose();
    }
  });

  testWidgets('choosing visible 32px uses display scale instead of storing 32 design pixels', (tester) async {
    final adapter = _resizedAdapter();
    try {
      await _openSettings(tester, adapter.editorState);
      final size32 = find.byKey(const ValueKey('date-card-font-0-32.0'));
      await Scrollable.ensureVisible(tester.element(size32), alignment: .5);
      await tester.pumpAndSettle();
      await tester.tap(size32);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('date-card-apply')));
      await tester.pumpAndSettle();
      final values = adapter.blocks.first.resource!.values;
      debugPrint('DISPLAY_FONT_RESULT=$values');
      final stored = double.parse((values['fsCalendar'] as String).split(' ').first);
      expect(stored * 2, 32.0, reason: '2倍卡片选择32px应保存16设计像素，与桌面contentScale合同一致');
    } finally {
      await tester.pumpWidget(const SizedBox());
      adapter.dispose();
    }
  });

  testWidgets('an imported tiny dotted border must not consume an unbounded painting budget', (tester) async {
    final document = BlockCraftJsonCodec.decode({
      'id': 'root',
      'flavour': 'root',
      'nodeType': 'root',
      'props': {},
      'meta': {},
      'children': [
        {
          'id': 'date',
          'flavour': 'date-card',
          'nodeType': 'void',
          'meta': {},
          'children': [],
          'props': {'date': '2026-10-25T09:30', 'bw': '1e-320px dotted'},
        },
      ],
    });
    final owner = DocumentEditorController(document: document);
    try {
      final values = CollabDateCard.readAttributes(document.root.children.single.attributes).values;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Offstage(
              child: SizedBox(width: 300, child: CollabDateCardVisual(card: CollabDateCard(values))),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final custom = tester.widget<CustomPaint>(
        find.byWidgetPredicate(
          (widget) => widget is CustomPaint && widget.foregroundPainter?.runtimeType.toString() == '_DateBorder',
          skipOffstage: false,
        ),
      );
      final canvas = _BudgetCanvas();
      debugPrint('TINY_BORDER_IMPORT=${values['bw']}');
      expect(
        () => custom.foregroundPainter!.paint(canvas, const Size(160, 137)),
        returnsNormally,
        reason: '非法/极小边框须回落或限制dash数量，不能在UI Isolate连续执行超过10000次绘制',
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(owner.close);
    }
  });
  for (final scenario in [
    (size: const Size(390, 844), scale: 1.0, keyboard: 0.0),
    (size: const Size(320, 568), scale: 1.5, keyboard: 0.0),
    (size: const Size(320, 720), scale: 2.2, keyboard: 0.0),
    (size: const Size(640, 360), scale: 1.0, keyboard: 120.0),
  ]) {
    testWidgets('bottom settings keeps header/actions fixed at ${scenario.size}/${scenario.scale}', (tester) async {
      await tester.binding.setSurfaceSize(scenario.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = _resizedAdapter();
      try {
        await _openSettings(
          tester,
          adapter.editorState,
          size: scenario.size,
          scale: scenario.scale,
          keyboard: scenario.keyboard,
        );
        expect(find.byType(Dialog), findsNothing);
        expect(find.byType(CollabBottomSheet), findsOneWidget);
        final sheet = find.byKey(const ValueKey('date-card-settings-sheet'));
        final apply = find.byKey(const ValueKey('date-card-apply'));
        final before = tester.getRect(apply);
        final heading = tester.getRect(find.text('日期设置'));
        expect(tester.getRect(sheet).bottom, closeTo(scenario.size.height, .1));
        expect(before.bottom, lessThanOrEqualTo(scenario.size.height - scenario.keyboard));
        final preview = find.byKey(const ValueKey('date-card-settings-preview'));
        final label = find.byKey(const ValueKey('date-card-style-name'));
        final previewBefore = tester.getRect(preview);
        final labelBefore = tester.getRect(label);
        final painted = find.descendant(
          of: preview,
          matching: find.byWidgetPredicate((widget) => widget is CustomPaint && widget.foregroundPainter != null),
        );
        expect(tester.getRect(painted).center.dx, closeTo(scenario.size.width / 2, 1));
        expect(labelBefore.top, greaterThanOrEqualTo(previewBefore.bottom));
        expect(find.text('样式'), findsNothing);
        expect(tester.takeException(), isNull);
        if (scenario.size.width == 390 || scenario.size.width == 320 && scenario.scale == 1.5) {
          await _capture(tester, 'date-settings-sticky-${scenario.size.width.toInt()}-${scenario.scale}');
        }
        await tester.drag(find.byKey(const ValueKey('date-card-settings-content')), const Offset(0, -600));
        await tester.pumpAndSettle();
        expect(tester.getRect(apply), before);
        expect(tester.getRect(find.text('日期设置')), heading);
        expect(tester.getRect(preview), previewBefore);
        expect(tester.getRect(label), labelBefore);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(adapter.editorState.undoManager.undoStack.isEmpty, isTrue);
      } finally {
        await tester.pumpWidget(const SizedBox());
        adapter.dispose();
      }
    });
  }

  testWidgets('arrows cycle every named style with centered preview and no writes before apply', (tester) async {
    final adapter = _resizedAdapter();
    try {
      await _openSettings(tester, adapter.editorState);
      for (final style in collabDateCardStyles.entries) {
        expect(tester.widget<Text>(find.byKey(const ValueKey('date-card-style-name'))).data, style.value);
        final preview = find.byKey(const ValueKey('date-card-settings-preview'));
        final painted = find.descendant(
          of: preview,
          matching: find.byWidgetPredicate((widget) => widget is CustomPaint && widget.foregroundPainter != null),
        );
        expect(tester.getRect(painted).center.dx, closeTo(400, 1), reason: style.key);
        expect(adapter.blocks.first.resource!.values['style'], 'calendar');
        await tester.tap(find.byKey(const ValueKey('date-card-style-next')));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: style.key);
      }
      expect(tester.widget<Text>(find.byKey(const ValueKey('date-card-style-name'))).data, '台历');
      await tester.tap(find.byKey(const ValueKey('date-card-style-previous')));
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const ValueKey('date-card-style-name'))).data, '双轨');
      await tester.tap(find.byKey(const ValueKey('date-card-style-next')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('date-card-apply')));
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.resource!.values['width'], 336);
      expect(adapter.editorState.undoManager.undoStack.isEmpty, isTrue);
      await _openSettings(tester, adapter.editorState);
      adapter.editorState.editable = false;
      await tester.pump();
      for (final side in ['previous', 'next']) {
        expect(tester.widget<IconButton>(find.byKey(ValueKey('date-card-style-$side'))).onPressed, isNull);
      }
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    } finally {
      await tester.pumpWidget(const SizedBox());
      adapter.dispose();
    }
  });

  testWidgets('swiping the bottom sheet away discards its draft', (tester) async {
    final adapter = _resizedAdapter();
    try {
      await _openSettings(tester, adapter.editorState);
      await chooseDateCardStyle(tester, 'pill');
      await tester.drag(find.text('日期设置'), const Offset(0, 700));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('date-card-settings-sheet')), findsNothing);
      expect(adapter.blocks.first.resource!.values['style'], 'calendar');
      expect(adapter.blocks.first.resource!.values['width'], 336);
      expect(adapter.editorState.undoManager.undoStack.isEmpty, isTrue);
    } finally {
      await tester.pumpWidget(const SizedBox());
      adapter.dispose();
    }
  });
}

/// 创建一个桌面按默认固定框等比放大2倍的正式日期投影，由各测试释放。
AppFlowyBlockEditorAdapter _resizedAdapter() => AppFlowyBlockEditorAdapter(
  initialBlocks: [
    CollabEditorBlock(
      id: 'date',
      blockType: 'date-card',
      text: '',
      resource: CollabResource.fromValues({
        'date': '2026-10-25T09:30',
        'style': 'calendar',
        'format': 'full',
        'width': 336.0,
        'height': 289.504,
      }),
    ),
    const CollabEditorBlock(id: 'p', blockType: 'paragraph', text: '正文'),
  ],
  onLocalBlocksChanged: (_) {},
);

/// 在 [tester] 中为借用 [state] 打开底部设置面板；[size]/[scale]控制视口和文字倍率。
/// [keyboard]为模拟键盘高度（逻辑像素），默认0；不释放外部编辑器。
Future<void> _openSettings(
  WidgetTester tester,
  EditorState state, {
  Size? size,
  double scale = 1,
  double keyboard = 0,
}) async {
  const font = String.fromEnvironment('DATE_SETTINGS_PREVIEW_FONT');
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('date-settings-capture'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: font.isEmpty ? null : 'DateSettingsPreview'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: size,
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
            padding: EdgeInsets.zero,
          ),
          child: child!,
        ),
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => await showCollabDateCardSettings(context, state, 'date'),
              child: const Text('打开设置'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开设置'));
  await tester.pumpAndSettle();
}

/// 可选地把 [tester] 中当前面板保存为 [name] PNG；图像资源在写入后释放。
Future<void> _capture(WidgetTester tester, String name) async {
  const output = String.fromEnvironment('DATE_SETTINGS_PREVIEW_DIR');
  if (output.isEmpty) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('date-settings-capture')));
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(output).create(recursive: true);
      await File('$output/$name.png').writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

/// 阻止缺陷画笔实际挂死测试进程；超过10000次drawPath立即失败，不分配图形资源。
class _BudgetCanvas implements Canvas {
  /// 当前测试已经请求的路径绘制次数。
  int draws = 0;

  /// [path]/[paint]均借用；只记录请求，第10001次抛出预算错误以终止不受限循环。
  @override
  void drawPath(ui.Path path, Paint paint) {
    draws++;
    if (draws > 10000) throw StateError('PAINT_BUDGET_EXCEEDED: $draws drawPath calls');
  }

  /// [invocation]中的其他Canvas操作不属于当前点线探针，保持默认失败语义。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
