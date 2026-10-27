import 'dart:io';
import 'dart:ui' as ui;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_weather_settings.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/model/collab_weather.dart';
import 'package:cses_document_collab/src/ui/modal/collab_bottom_sheet.dart';
import 'package:cses_document_collab/src/ui/modal/collab_weather_visual.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 天气设置底部路由的固定头尾、窄屏/大字/键盘和下滑取消回归。
void main() {
  setUpAll(() async {
    const font = String.fromEnvironment('WEATHER_SETTINGS_PREVIEW_FONT');
    if (font.isEmpty) return;
    await (FontLoader(
      'WeatherSettingsPreview',
    )..addFont(File(font).readAsBytes().then(ByteData.sublistView))).load();
    await (FontLoader(
      'packages/lucide_icons_flutter/Lucide',
    )..addFont(rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'))).load();
  });

  for (final scenario in [
    (size: const Size(390, 844), scale: 1.0, keyboard: 0.0),
    (size: const Size(320, 568), scale: 1.5, keyboard: 0.0),
    (size: const Size(320, 720), scale: 2.2, keyboard: 0.0),
    (size: const Size(640, 360), scale: 1.0, keyboard: 120.0),
  ]) {
    testWidgets('weather sheet fixes header/actions at ${scenario.size}/${scenario.scale}', (tester) async {
      await tester.binding.setSurfaceSize(scenario.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = _adapter();
      try {
        await _open(
          tester,
          adapter.editorState,
          size: scenario.size,
          scale: scenario.scale,
          keyboard: scenario.keyboard,
        );
        expect(find.byType(Dialog), findsNothing);
        expect(find.byType(CollabBottomSheet), findsOneWidget);
        final sheet = find.byKey(const ValueKey('weather-settings-sheet'));
        final apply = find.byKey(const ValueKey('weather-apply'));
        final actions = tester.getRect(apply);
        final title = tester.getRect(find.text('天气设置'));
        final preview = tester.getRect(find.byKey(const ValueKey('weather-settings-preview')));
        final name = tester.getRect(find.byKey(const ValueKey('weather-style-name')));
        final previous = tester.getRect(find.byKey(const ValueKey('weather-style-previous')));
        expect(tester.getRect(sheet).bottom, closeTo(scenario.size.height, .1));
        expect(actions.bottom, lessThanOrEqualTo(scenario.size.height - scenario.keyboard));
        expect(tester.takeException(), isNull);
        if (scenario.size.width == 390) await _capture(tester);
        await tester.drag(find.byKey(const ValueKey('weather-settings-content')), const Offset(0, -600));
        await tester.pumpAndSettle();
        expect(tester.getRect(apply), actions);
        expect(tester.getRect(find.text('天气设置')), title);
        expect(tester.getRect(find.byKey(const ValueKey('weather-settings-preview'))), preview);
        expect(tester.getRect(find.byKey(const ValueKey('weather-style-name'))), name);
        expect(tester.getRect(find.byKey(const ValueKey('weather-style-previous'))), previous);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(adapter.editorState.undoManager.undoStack, isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox());
        adapter.dispose();
      }
    });
  }

  testWidgets('weather arrows cycle all seven styles with centered fixed preview and no premature writes', (
    tester,
  ) async {
    final adapter = _adapter(resized: true);
    final before = adapter.blocks.first.resource!.values;
    try {
      await _open(tester, adapter.editorState);
      expect(find.text('样式'), findsNothing);
      for (final entry in collabWeatherLayouts.entries) {
        expect(tester.widget<Text>(find.byKey(const ValueKey('weather-style-name'))).data, entry.value.label);
        expect(tester.widget<CollabWeatherVisual>(find.byType(CollabWeatherVisual)).weather!.temp, 20);
        final preview = find.byKey(const ValueKey('weather-settings-preview'));
        final painted = find.descendant(
          of: preview,
          matching: find.byWidgetPredicate(
            (widget) => widget is CustomPaint && widget.foregroundPainter != null,
          ),
        );
        expect(tester.getRect(painted).center.dx, closeTo(400, 1), reason: entry.key);
        expect(adapter.blocks.first.resource!.values, before);
        await tester.tap(find.byKey(const ValueKey('weather-style-next')));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: entry.key);
      }
      expect(tester.widget<Text>(find.byKey(const ValueKey('weather-style-name'))).data, '经典紧凑');
      await tester.tap(find.byKey(const ValueKey('weather-style-previous')));
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const ValueKey('weather-style-name'))).data, '气象分栏');
      await tester.tap(find.byKey(const ValueKey('weather-style-next')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('weather-apply')));
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.resource!.values, before);
      expect(adapter.editorState.undoManager.undoStack, isEmpty);
      expect(find.byKey(const ValueKey('weather-settings-sheet')), findsNothing);
      await _open(tester, adapter.editorState);
      adapter.editorState.editable = false;
      adapter.editorState.editable = true;
      await tester.pump();
      for (final side in ['previous', 'next']) {
        expect(tester.widget<IconButton>(find.byKey(ValueKey('weather-style-$side'))).onPressed, isNull);
      }
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    } finally {
      await tester.pumpWidget(const SizedBox());
      adapter.dispose();
    }
  });

  testWidgets('swiping weather sheet away discards changed draft', (tester) async {
    final adapter = _adapter();
    try {
      await _open(tester, adapter.editorState);
      await tester.tap(find.byKey(const ValueKey('weather-style-previous')));
      await tester.pump();
      await tester.drag(find.text('天气设置'), const Offset(0, 700));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('weather-settings-sheet')), findsNothing);
      expect(adapter.blocks.first.resource!.values['style'], 'classic');
      expect(adapter.editorState.undoManager.undoStack, isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox());
      adapter.dispose();
    }
  });
}

/// 为各用例创建独立卡片；[resized]默认false，true模拟桌面作者的2倍尺寸。
/// 调用方在视图卸载后释放返回的适配器。
AppFlowyBlockEditorAdapter _adapter({bool resized = false}) => AppFlowyBlockEditorAdapter(
  initialBlocks: [
    CollabEditorBlock(
      id: 'weather',
      blockType: 'weather',
      text: '',
      resource: CollabResource.fromValues({
        if (resized) ...{'width': 320, 'height': 84},
        'style': 'classic',
        'date': '2026-10-25',
        'frozen': {'temp': 20, 'condition': '晴', 'location': '北京'},
      }),
    ),
    const CollabEditorBlock(id: 'p', blockType: 'paragraph', text: '正文'),
  ],
  onLocalBlocksChanged: (_) {},
);

/// [tester]承载借用[state]的入口；[size]/[scale]/[keyboard]分别设置逻辑窗口、文字倍率及键盘高度。
/// 默认使用800×600逻辑像素、1倍字号和0键盘高度；不释放借用的编辑器。
Future<void> _open(
  WidgetTester tester,
  EditorState state, {
  Size size = const Size(800, 600),
  double scale = 1,
  double keyboard = 0,
}) async {
  const font = String.fromEnvironment('WEATHER_SETTINGS_PREVIEW_FONT');
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: font.isEmpty ? null : 'WeatherSettingsPreview'),
      builder: (context, child) => MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(scale),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => await showCollabWeatherSettings(context, state, 'weather'),
            child: const Text('设置'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('设置'));
  await tester.pumpAndSettle();
}

/// 将[tester]中的实际底部面板保存到可选环境目录；无输出配置时不截图。
Future<void> _capture(WidgetTester tester) async {
  const output = String.fromEnvironment('WEATHER_SETTINGS_PREVIEW_DIR');
  if (output.isEmpty) return;
  final sheet = tester.element(find.byKey(const ValueKey('weather-settings-sheet')));
  RenderObject? render = sheet.findRenderObject();
  while (render is! RenderRepaintBoundary && render != null) {
    render = render.parent;
  }
  if (render is! RenderRepaintBoundary) return;
  final boundary = render;
  await tester.runAsync(() async {
    final capture = await boundary.toImage(pixelRatio: 2);
    final bytes = await capture.toByteData(format: ui.ImageByteFormat.png);
    await Directory(output).create(recursive: true);
    await File('$output/weather-style-navigation.png').writeAsBytes(bytes!.buffer.asUint8List());
    capture.dispose();
  });
}
