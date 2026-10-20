import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' show FrameTiming;
import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:cses_document_collab/src/ui/modal/collab_bottom_sheet.dart';
import 'package:cses_document_collab/src/ui/modal/collab_emoji_picker.dart';

/// 在Android性能模式验证实际共用底部弹窗、表情目录及Tab，采集真实引擎帧耗时。
/// 仅使用隔离回调，不初始化账号、业务服务、原生协同或网络；完成后需覆盖恢复普通Demo。
void main() {
  if (const bool.fromEnvironment('EMOJI_MANUAL_PERF')) {
    _runNativeTouchFixture();
    return;
  }
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Respect engine/device scheduling; pumped test delays must not suppress animation frames.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;
  testWidgets('physical Android emoji scrolling and linked tabs performance', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue);
    expect(kProfileMode, isTrue, reason: '帧耗时必须来自profile构建');
    final selected = <String>[];
    await tester.pumpWidget(_EmojiDeviceFixture(onSelected: selected.add));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-emoji')));
    await tester.pumpAndSettle();
    final list = find.byKey(const PageStorageKey('device-emoji-list'));
    final tabs = find.byKey(const ValueKey('device-emoji-categories'));
    final search = find.byKey(const ValueKey('device-emoji-search'));
    final searchRect = tester.getRect(search);
    final tabRect = tester.getRect(tabs);
    final count = tester
        .widget<ListView>(list)
        .childrenDelegate
        .estimatedChildCount;
    binding.reportData = {
      'deviceView': {
        'physicalWidth': tester.view.physicalSize.width,
        'physicalHeight': tester.view.physicalSize.height,
        'devicePixelRatio': tester.view.devicePixelRatio,
        'refreshRate': tester.view.display.refreshRate,
        'profile': kProfileMode,
      },
    };

    // Capture first-use glyph rendering separately from warmed scrolling.
    await binding.watchPerformance(() async {
      for (var index = 1; index <= 8; index++) {
        await _choose(tester, index);
        _expectHeading(tester, index);
        expect(
          tester.widget<ListView>(list).childrenDelegate.estimatedChildCount,
          count,
        );
      }
    }, reportKey: 'first_category_cycle');

    await _choose(tester, 0);
    final controller = tester.widget<TabBar>(tabs).controller!;
    final seen = <int>{0};

    /// 仅记录已选中的分类索引，不修改组件或业务状态。
    void recordCategory() => seen.add(controller.index);
    controller.addListener(recordCategory);
    try {
      await binding.watchPerformance(() async {
        for (final direction in [-1.0, 1.0]) {
          for (var i = 0; i < 14; i++) {
            await tester.fling(list, Offset(0, direction * 310), 2200);
            await tester.pumpAndSettle();
            expect(tester.getRect(search), searchRect);
            expect(tester.getRect(tabs), tabRect);
            expect(
              tester.getRect(_tab(controller.index)).overlaps(tabRect),
              isTrue,
            );
            expect(find.byType(Tooltip).evaluate().length, lessThan(180));
          }
        }
      }, reportKey: 'continuous_bidirectional_fling');
    } finally {
      controller.removeListener(recordCategory);
    }
    expect(seen, containsAll([0, 1, 2, 3, 4, 5, 6, 7, 8]));
    binding.reportData!['categoriesSeenByFling'] = seen.toList()..sort();

    await binding.watchPerformance(() async {
      for (final index in [8, 0, 5, 2, 7, 1, 6, 3, 4]) {
        await _choose(tester, index);
        if (index > 0) _expectHeading(tester, index);
      }
      await _choose(tester, 0);
      final flags = _tab(8);
      await tester.ensureVisible(flags);
      await tester.pumpAndSettle();
      await tester.tap(flags);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(_tab(7));
      await tester.pumpAndSettle();
      expect(controller.index, 7);
      _expectHeading(tester, 7);
      await _choose(tester, 0);
      await tester.ensureVisible(flags);
      await tester.pumpAndSettle();
      await tester.tap(flags);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.drag(list, const Offset(0, 180));
      await tester.pumpAndSettle();
      expect(controller.index, isNot(8));
      final offset = tester.widget<ListView>(list).controller!.offset;
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<ListView>(list).controller!.offset, offset);
    }, reportKey: 'warm_tabs_and_interruption');

    await _choose(tester, 2);
    final beforeHorizontal = tester.widget<ListView>(list).controller!.offset;
    await binding.watchPerformance(() async {
      for (var i = 0; i < 4; i++) {
        await tester.fling(tabs, const Offset(-220, 0), 1500);
        await tester.pumpAndSettle();
        await tester.fling(tabs, const Offset(220, 0), 1500);
        await tester.pumpAndSettle();
      }
    }, reportKey: 'horizontal_tab_fling');
    expect(tester.widget<ListView>(list).controller!.offset, beforeHorizontal);
    expect(controller.index, 2);
    expect(selected, isEmpty, reason: '浏览和定位不得保存文档');

    binding.testTextInput.register();
    addTearDown(binding.testTextInput.unregister);
    await tester.enterText(search, '宇航员');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller!.text, '宇航员');
    await tester.tap(find.byKey(const ValueKey('device-emoji-skin-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('device-emoji-skin-3')));
    await tester.pumpAndSettle();
    final astronaut = find.byKey(const ValueKey('device-emoji-👩🏽‍🚀'));
    await tester.ensureVisible(astronaut);
    await tester.tap(astronaut);
    await tester.pumpAndSettle();
    expect(selected, ['👩🏽‍🚀']);
    await _choose(tester, 2);
    _expectHeading(tester, 2);
    binding.reportData!['functionalChecks'] = {
      'allEightCategoryAnchors': true,
      'bidirectionalFlingAndVisibleTab': true,
      'rapidLastTargetAndDragInterruption': true,
      'horizontalTabsKeepListPosition': true,
      'fixedSearchAndTabRects': true,
      'lazyButtonsBelow180': true,
      'searchSkinAndFullUnicodeSave': selected.single,
    };
    // Surface conversion happens only after all performance windows.
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();
    await binding.takeScreenshot('emoji-tabs-nature');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

/// 启动纯Widgets绑定的同一临时界面，供系统触摸和VM服务独立核验帧耗时。
/// 帧缓存与扩展仅存活于此测试进程，最多保留20000帧；reset=true清除当前采样，不读取文档。
void _runNativeTouchFixture() {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final frames = <List<int>>[];
  binding.addTimingsCallback((List<FrameTiming> values) {
    for (final value in values) {
      frames.add([
        value.buildDuration.inMicroseconds,
        value.rasterDuration.inMicroseconds,
      ]);
    }
    if (frames.length > 20000) frames.removeRange(0, frames.length - 20000);
  });
  developer.registerExtension('ext.emoji.frames', (method, parameters) async {
    if (parameters['reset'] == 'true') frames.clear();
    return developer.ServiceExtensionResponse.result(
      jsonEncode({'frames': frames}),
    );
  });
  runApp(_EmojiDeviceFixture(onSelected: (_) {}));
}

/// 返回[index]对应的真实Tab；0为全部，其余遵循桌面八类顺序。
Finder _tab(int index) => find.byKey(
  ValueKey(
    'device-emoji-category-${['all', 'people', 'nature', 'foods', 'activity', 'places', 'objects', 'symbols', 'flags'][index]}',
  ),
);

/// 在[tester]中点击[index]对应的可见Tab，等待短距滚动或远距过渡及Tab动画完成。
Future<void> _choose(WidgetTester tester, int index) async {
  final tab = _tab(index);
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
  expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, index);
  expect(
    tester.getRect(tab).overlaps(tester.getRect(find.byType(TabBar))),
    isTrue,
  );
}

/// 在[tester]的实际列表中核对[index]分类标题顶边与视口对齐，容忍1逻辑像素舍入。
void _expectHeading(WidgetTester tester, int index) {
  final name = [
    '表情与人物',
    '动物与自然',
    '食物与饮料',
    '活动与运动',
    '旅行与地点',
    '物品',
    '符号',
    '旗帜',
  ][index - 1];
  expect(
    tester.getTopLeft(find.byKey(ValueKey('device-emoji-heading-$name'))).dy,
    closeTo(
      tester
          .getTopLeft(find.byKey(const PageStorageKey('device-emoji-list')))
          .dy,
      1,
    ),
  );
}

/// 真实公共底部路由与共用选择器的隔离宿主，不创建账户或业务资源。
class _EmojiDeviceFixture extends StatelessWidget {
  /// [onSelected]借用本地记录回调，只有明确选择表情时调用，不访问文档。
  const _EmojiDeviceFixture({required this.onSelected});

  /// 本地选择记录，测试持有；不写磁盘或网络。
  final ValueChanged<String> onSelected;

  /// 用[context]构建可重复打开的真实底部弹窗，路由退出由公共入口等待完成。
  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: FilledButton(
            key: const ValueKey('open-emoji'),
            onPressed: () async {
              await showCollabBottomSheet<void>(
                context: context,
                builder: (sheetContext) => CollabBottomSheet(
                  title: const Text('设置表情'),
                  icon: LucideIcons.smile,
                  expand: true,
                  scrollBody: false,
                  leadingAction: TextButton(
                    onPressed: () {},
                    child: const Text('移除'),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: const Text('完成'),
                    ),
                  ],
                  child: CollabEmojiPicker(
                    keyPrefix: 'device-emoji',
                    current: '😸',
                    onSelected: (value) async {
                      onSelected(value);
                    },
                  ),
                ),
              );
            },
            child: const Text('打开表情测试'),
          ),
        ),
      ),
    ),
  );
}
