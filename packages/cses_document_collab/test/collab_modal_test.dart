import 'dart:io';
import 'dart:ui' as ui;

import 'package:cses_document_collab/src/editor/editor_media_source_sheet.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:cses_document_collab/src/model/editor_media_upload.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 验证共用弹窗的路由生命周期、窄屏/键盘布局与真实来源面板。
void main() {
  setUpAll(_loadFont);
  testWidgets('result waits for the entire reverse transition', (tester) async {
    final context = await _mount(tester);
    var completed = false;
    final result = showCollabBottomSheet<String>(
      context: context,
      builder: (context) => CollabBottomSheet(
        title: const Text('修改标题'),
        icon: LucideIcons.type,
        actions: [
          FilledButton(onPressed: () => Navigator.pop(context, '名称'), child: const Text('保存')),
        ],
        child: const Text('内容'),
      ),
    );
    final completion = result.then((value) {
      completed = true;
      return value;
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(completed, isFalse);
    await tester.pumpAndSettle();
    expect(await completion, '名称');
  });
  for (final (size, scale, keyboard) in [
    (const Size(390, 844), 1.0, 0.0),
    (const Size(320, 568), 1.5, 200.0),
    (const Size(320, 568), 2.2, 200.0),
    (const Size(568, 320), 1.0, 100.0),
  ]) {
    testWidgets('fixed close/save remain reachable: $size / $scale / $keyboard', (tester) async {
      final context = await _mount(tester, size: size, scale: scale, keyboard: keyboard);
      final result = showCollabBottomSheet<void>(context: context, builder: (_) => _sheet());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final finder in [find.byTooltip('关闭'), find.text('保存')]) {
        final rect = tester.getRect(finder);
        expect(rect.bottom, lessThanOrEqualTo(size.height - keyboard));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(size.width));
      }
      final before = tester.getRect(find.text('保存'));
      await tester.drag(find.byType(SingleChildScrollView).last, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('保存')), before);
      if (keyboard == 0) await _capture(tester, 'bottom-sheet');
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await result;
    });
  }
  for (final contentHeight in [24.0, 1000.0]) {
    for (final safeBottom in [0.0, 34.0]) {
      for (final keyboard in [0.0, 200.0]) {
        testWidgets(
          'expanded sheet pins actions above safe area: content=$contentHeight safe=$safeBottom keyboard=$keyboard',
          (tester) async {
            final context = await _mount(tester, keyboard: keyboard, safeBottom: safeBottom);
            final result = showCollabBottomSheet<void>(
              context: context,
              builder: (context) => CollabBottomSheet(
                title: const Text('修改图标'),
                icon: LucideIcons.smile,
                expand: true,
                actions: [
                  FilledButton(onPressed: () => Navigator.pop(context), child: const Text('完成')),
                ],
                child: SizedBox(height: contentHeight, child: const Text('表情内容')),
              ),
            );
            await tester.pumpAndSettle();
            final done = find.widgetWithText(FilledButton, '完成');
            final bottomPadding = keyboard == 0 && safeBottom > 22 ? safeBottom : 22.0;
            expect(
              tester.getRect(done).bottom,
              closeTo(844 - keyboard - bottomPadding - 2, .1),
              reason: '按钮下方仅保留安全区/设计留白与2像素操作区内边距',
            );
            final before = tester.getRect(done);
            await tester.drag(find.byType(SingleChildScrollView).last, const Offset(0, -100));
            await tester.pumpAndSettle();
            expect(tester.getRect(done), before);
            expect(tester.takeException(), isNull);
            await tester.tap(done);
            await tester.pumpAndSettle();
            await result;
          },
        );
      }
    }
  }
  testWidgets('dialog uses the shared surface and returns confirmation', (tester) async {
    final context = await _mount(tester);
    final result = showCollabDialog<bool>(
      context: context,
      builder: (context) => CollabDialog(
        title: const Text('文字链接'),
        icon: LucideIcons.link,
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
        ],
        content: const CollabModalField(
          label: '链接地址',
          child: TextField(decoration: InputDecoration(hintText: 'https://example.com')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    expect(dialog.insetPadding, const EdgeInsets.all(24));
    expect((dialog.shape! as RoundedRectangleBorder).borderRadius, BorderRadius.circular(20));
    await _capture(tester, 'dialog');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
  });
  testWidgets('dark appearance keeps opaque surfaces and paired primary labels', (tester) async {
    final context = await _mount(tester, dark: true);
    final result = showCollabBottomSheet<void>(context: context, builder: (_) => _sheet());
    await tester.pumpAndSettle();
    final colors = CollabModalColors.of(tester.element(find.byType(CollabModalField)));
    expect(colors.surface, const Color(0xFF202126));
    expect(colors.accent, const Color(0xFFB0A5FF));
    expect(colors.onAccent, const Color(0xFF231751));
    await _capture(tester, 'bottom-sheet-dark');
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await result;
  });
  testWidgets('media source keeps editable draft and returns the selected URL', (tester) async {
    final context = await _mount(tester);
    final result = showEditorMediaSourceSheet(
      context,
      blockType: 'image',
      service: _PreviewUpload(),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('editor-url-block-input')),
      'https://example.com/image.png',
    );
    await tester.pumpAndSettle();
    await _capture(tester, 'media-source');
    await tester.tap(find.byKey(const ValueKey('editor-url-block-submit')));
    await tester.pumpAndSettle();
    expect((await result)!.url, 'https://example.com/image.png');
  });
  testWidgets('popover clamps a right-edge anchor and returns the chosen action', (tester) async {
    await _mount(tester, anchor: true);
    final anchor = tester.element(find.byKey(const ValueKey('anchor')));
    final result = showCollabPopover<String>(
      context: anchor,
      title: '列操作',
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CollabMenuRow(
            leading: const Icon(LucideIcons.panelLeftOpen),
            title: const Text('在左侧插入列'),
            onTap: () => Navigator.pop(context, 'before'),
          ),
          CollabMenuRow(
            leading: const Icon(LucideIcons.panelRightOpen),
            title: const Text('在右侧插入列'),
            onTap: () => Navigator.pop(context, 'after'),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final bounds = tester.getRect(find.byType(CollabPopover));
    expect(bounds.right, lessThanOrEqualTo(382));
    expect(bounds.left, greaterThanOrEqualTo(8));
    await _capture(tester, 'popover');
    await tester.tap(find.text('在左侧插入列'));
    await tester.pumpAndSettle();
    expect(await result, 'before');
  });
}

/// 建立 [tester] 的文档画布并返回页面上下文。
/// [size]/[scale]/[keyboard] 分别指定逻辑尺寸、文字缩放和键盘高度；
/// [dark] 控制亮度，[anchor] 为 true 时添加右侧锚点；[safeBottom] 为底部系统安全区，默认0逻辑像素。
/// 结束后恢复测试尺寸。
Future<BuildContext> _mount(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double scale = 1,
  double keyboard = 0,
  bool dark = false,
  bool anchor = false,
  double safeBottom = 0,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  late BuildContext context;
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('capture'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: dark ? Brightness.dark : Brightness.light,
          fontFamily: Platform.environment['COLLAB_MODAL_PREVIEW_FONT'] == null
              ? null
              : 'ModalPreview',
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: size,
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
            viewPadding: EdgeInsets.only(bottom: safeBottom),
            padding: EdgeInsets.only(bottom: safeBottom > keyboard ? safeBottom - keyboard : 0),
          ),
          child: child!,
        ),
        home: Scaffold(
          backgroundColor: dark ? const Color(0xFF202126) : Colors.white,
          resizeToAvoidBottomInset: false,
          body: Builder(
            builder: (value) {
              context = value;
              return Padding(
                padding: const EdgeInsets.fromLTRB(24, 50, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('产品与设计 / 项目文档', style: TextStyle(fontSize: 11)),
                    const SizedBox(height: 16),
                    const Text(
                      '让想法一起生长',
                      style: TextStyle(fontSize: 25, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 20),
                    const Text('把分散的灵感连接起来，让每一次协作都清晰、有序。'),
                    if (anchor)
                      const Align(
                        alignment: Alignment.centerRight,
                        child: SizedBox(
                          key: ValueKey('anchor'),
                          width: 32,
                          height: 32,
                          child: Icon(LucideIcons.ellipsis),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return context;
}

/// 构建长内容和固定分类/操作区的共用外壳，不拥有业务控制器。
Widget _sheet() => Builder(
  builder: (context) => CollabBottomSheet(
    title: const Text('数学公式'),
    subtitle: '编辑 LaTeX，实时预览',
    icon: LucideIcons.sigma,
    header: const Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: CollabModalSegments<int>(values: {0: '源码', 1: '预览'}, selected: 0, onSelected: null),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: () => Navigator.pop(context), child: const Text('保存')),
    ],
    child: const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        CollabModalField(
          label: 'LaTeX 源码',
          child: TextField(
            minLines: 3,
            maxLines: 3,
            decoration: InputDecoration(hintText: 'E = mc²'),
          ),
        ),
        SizedBox(
          height: 300,
          child: Align(alignment: Alignment.topLeft, child: Text('公式预览')),
        ),
      ],
    ),
  ),
);

/// 按环境变量加载中文预览字体；普通回归不依赖本机字体。
Future<void> _loadFont() async {
  final path = Platform.environment['COLLAB_MODAL_PREVIEW_FONT'];
  if (path == null) return;
  await (FontLoader(
    'packages/lucide_icons_flutter/Lucide',
  )..addFont(rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'))).load();
  final bytes = await File(path).readAsBytes();
  await (FontLoader('ModalPreview')..addFont(Future.value(ByteData.sublistView(bytes)))).load();
}

/// 将 [tester] 的真实画布保存为 [name] PNG，仅显式指定预览目录时输出。
/// 仅捕获期间启用真实阴影并重绘，finally恢复调试标志；写入后释放图像。
Future<void> _capture(WidgetTester tester, String name) async {
  final output = Platform.environment['COLLAB_MODAL_PREVIEW_DIR'];
  if (output == null) return;
  final previousShadows = debugDisableShadows;
  debugDisableShadows = false;
  try {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')),
    );

    /// 将借用的 [object] 及其绘制子树标记重绘，不修改组件状态或业务控制器。
    void repaint(RenderObject object) {
      object.markNeedsPaint();
      object.visitChildren(repaint);
    }

    repaint(boundary);
    await tester.pump();
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('capture')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(output).create(recursive: true);
        await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  } finally {
    debugDisableShadows = previousShadows;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')),
    );

    /// 恢复借用 [object] 的测试绘制状态，保持全局调试标志不泄漏到其他用例。
    void repaint(RenderObject object) {
      object.markNeedsPaint();
      object.visitChildren(repaint);
    }

    repaint(boundary);
    await tester.pump();
  }
}

/// 提供可展示上传入口的测试端口，不打开系统选择器或执行网络请求。
class _PreviewUpload extends EditorMediaUploadService {
  /// [kind] 为资源类型，本预览直接取消本地文件选择。
  @override
  Future<EditorLocalFile?> pickFile(String kind) async => null;

  /// [file]/[kind] 为请求资源；[cancelToken]/[onProgress] 由面板持有。
  /// 预览不执行上传，误调用时同步抛出StateError以暴露测试配置错误。
  @override
  Future<EditorMediaSource> upload(
    EditorLocalFile file,
    String kind, {
    required CancelToken cancelToken,
    required void Function(double) onProgress,
  }) => throw StateError('预览测试不执行上传');
}
