import 'dart:ui' as ui;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_code_block.dart';
import 'package:cses_document_collab/src/editor/collab_code_editing.dart';
import 'package:cses_document_collab/src/model/collab_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用实际行号像素与正文光标位置核对软折行对齐、空行和输入后更新。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(0.0),
          ),
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          null,
        );
  });
  for (final width in [280.0, 320.0, 390.0]) {
    for (final scale in [1.0, 1.5, 2.2]) {
      testWidgets('logical numbers align after wrapping at $width / $scale', (
        tester,
      ) async {
        final source = '${'print(long_variable_name); ' * 4}\n\n中文😀\n';
        final changes = <List<CollabEditorBlock>>[];
        final adapter = _adapter(source, changes.add);
        addTearDown(adapter.dispose);
        final before = adapter.editorState.document.first!.delta!.toJson();
        await _pump(tester, adapter, width: width, scale: scale);
        final rows = await _inkRows(tester);
        expect(rows, hasLength(4));
        final paragraph = _body(tester, source);
        final starts = [
          0,
          for (var i = 0; i < source.length; i++)
            if (source[i] == '\n') i + 1,
        ];
        final measure = TextPainter(
          text: paragraph.text,
          textDirection: paragraph.textDirection,
          textScaler: paragraph.textScaler,
          textHeightBehavior: paragraph.textHeightBehavior,
          locale: paragraph.locale,
        )..layout(maxWidth: paragraph.size.width);
        final baselines = [
          for (final line in measure.computeLineMetrics())
            if (starts.contains(
              paragraph.getPositionForOffset(Offset(0, line.baseline)).offset,
            ))
              line.baseline,
        ];
        measure.dispose();
        expect(baselines, hasLength(4));
        expect(baselines[1] - baselines[0], greaterThan(13 * 1.8 * scale * 2));
        final topOffset = rows.first - baselines.first;
        for (var i = 0; i < rows.length; i++) {
          expect(rows[i] - baselines[i], closeTo(topOffset, 1.5));
        }
        expect(adapter.editorState.document.first!.delta!.toJson(), before);
        expect(changes, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final source in ['', '\n', '\n\n', 'a\n']) {
    testWidgets(
      'empty logical lines have visible numbers: ${source.codeUnits}',
      (tester) async {
        final adapter = _adapter(source, (_) {});
        addTearDown(adapter.dispose);
        await _pump(tester, adapter);
        expect(
          await _inkRows(tester),
          hasLength('\n'.allMatches(source).length + 1),
        );
      },
    );
  }
  testWidgets(
    'numbers follow Enter, undo, remote text and folding in preview',
    (tester) async {
      final adapter = _adapter('abc', (_) {});
      addTearDown(adapter.dispose);
      await _pump(tester, adapter);
      expect(await _inkRows(tester), hasLength(1));
      final state = adapter.editorState;
      state.selection = Selection.single(path: [0], startOffset: 1);
      await collabCodeEnter.handler(state);
      await tester.pumpAndSettle();
      expect(adapter.blocks.single.text, 'a\nbc');
      expect(await _inkRows(tester), hasLength(2));
      state.undoManager.undo();
      await tester.pumpAndSettle();
      expect(await _inkRows(tester), hasLength(1));
      await adapter.replaceFromRemote(const [
        CollabEditorBlock(
          id: 'code',
          blockType: csesCodeBlockType,
          text: 'one\ntwo\nthree',
          code: CollabCode(language: 'Dart', name: '示例'),
        ),
      ]);
      await tester.pumpAndSettle();
      expect(await _inkRows(tester), hasLength(3));
      await _pump(tester, adapter, editable: false);
      expect(await _inkRows(tester), hasLength(3));
      await tester.tap(find.byKey(const ValueKey('collab-code-collapse')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('collab-code-line-numbers')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('collab-code-collapse')));
      await tester.pumpAndSettle();
      expect(await _inkRows(tester), hasLength(3));
      expect(adapter.blocks.single.text, 'one\ntwo\nthree');
      expect(adapter.blocks.single.code!.collapsed, isFalse);
    },
  );
  testWidgets('gutter grows to accommodate three digit numbers', (
    tester,
  ) async {
    final adapter = _adapter(List.filled(100, 'x').join('\n'), (_) {});
    addTearDown(adapter.dispose);
    await _pump(tester, adapter);
    final paragraph = _body(tester, adapter.blocks.single.text);
    final gutter = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('collab-code-line-numbers')),
    );
    final left =
        paragraph.localToGlobal(Offset.zero).dx -
        gutter.localToGlobal(Offset.zero).dx;
    final number = TextPainter(
      text: TextSpan(text: '100', style: paragraph.text.style),
      textDirection: TextDirection.ltr,
    )..layout();
    expect(left, greaterThan(number.width + 16));
    number.dispose();
    expect(tester.takeException(), isNull);
  });
}

/// 创建正文为[text]的代码适配器；[onChanged]观察本地事务，调用方负责释放适配器。
AppFlowyBlockEditorAdapter _adapter(
  String text,
  ValueChanged<List<CollabEditorBlock>> onChanged,
) => AppFlowyBlockEditorAdapter(
  initialBlocks: [
    CollabEditorBlock(
      id: 'code',
      blockType: csesCodeBlockType,
      text: text,
      code: const CollabCode(language: 'Dart', name: '示例'),
    ),
  ],
  onLocalBlocksChanged: onChanged,
);

/// 用借用[tester]挂载[adapter]；[width]为逻辑像素，[scale]为正文倍率，[editable]控制编辑模式。
/// 测试结束恢复屏幕尺寸，编辑器仍由调用方释放。
Future<void> _pump(
  WidgetTester tester,
  AppFlowyBlockEditorAdapter adapter, {
  double width = 390,
  double scale = 1,
  bool editable = true,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        AppFlowyEditorLocalizations.delegate,
      ],
      home: Scaffold(
        body: AppFlowyEditor(
          editorState: adapter.editorState,
          editable: editable,
          disableKeyboardService: !editable,
          editorStyle: EditorStyle.mobile(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            textScaleFactor: scale,
          ),
          characterShortcutEvents: [
            collabCodeEnter,
            ...standardCharacterShortcutEvents,
          ],
          blockComponentBuilders: {
            ...standardBlockComponentBuilderMap,
            csesCodeBlockType: CollabCodeBlockComponentBuilder(),
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 返回借用[tester]中原文为[source]的真实正文RenderParagraph，排除占位与补全层。
RenderParagraph _body(WidgetTester tester, String source) =>
    tester.renderObject<RenderParagraph>(
      find
          .descendant(
            of: find.byType(AppFlowyRichText),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is RichText && widget.text.toPlainText() == source,
            ),
          )
          .first,
    );

/// 截取借用[tester]的透明行号层，返回数字墨迹的每个顶部行；不计竖向分隔线。
/// 图像和字节只在本次断言使用，读取后立即释放图像。
Future<List<int>> _inkRows(WidgetTester tester) async {
  return (await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('collab-code-line-numbers')),
    );
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final body = tester.renderObject<RenderBox>(
        find.byType(AppFlowyRichText),
      );
      final gutter =
          (body.localToGlobal(Offset.zero).dx -
                  boundary.localToGlobal(Offset.zero).dx)
              .floor();
      final rows = <int>[];
      var previous = false;
      for (var y = 0; y < image.height; y++) {
        var ink = false;
        for (var x = 0; x < gutter - 17; x++) {
          if (data.getUint8((y * image.width + x) * 4 + 3) != 0) {
            ink = true;
            break;
          }
        }
        if (ink && !previous) rows.add(y);
        previous = ink;
      }
      return rows;
    } finally {
      image.dispose();
    }
  }))!;
}
