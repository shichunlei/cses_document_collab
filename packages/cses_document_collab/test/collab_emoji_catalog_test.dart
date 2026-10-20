import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:cses_document_collab/src/model/collab_emoji_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:cses_document_collab/src/ui/modal/collab_bottom_sheet.dart';
import 'package:cses_document_collab/src/ui/modal/collab_emoji_picker.dart';

/// 验证桌面同源目录、中文/英文搜索、完整肤色序列、惰性浏览与底部弹窗约束。
void main() {
  setUpAll(_loadPreviewFonts);
  test(
    'desktop catalog contains eight unique groups and complete native sequences',
    () {
      expect(collabEmojiCategories.map((entry) => entry.id), [
        'people',
        'nature',
        'foods',
        'activity',
        'places',
        'objects',
        'symbols',
        'flags',
      ]);
      expect(allCollabEmojis.length, 1812);
      expect(
        allCollabEmojis.map((entry) => entry.native).toSet(),
        hasLength(allCollabEmojis.length),
      );
      expect(allCollabEmojis.expand((entry) => entry.tones), hasLength(1350));
      expect(findCollabEmoji('👩‍💻')!.withSkinTone(3), '👩🏽‍💻');
      expect(findCollabEmoji('👩🏽‍💻')!.native, '👩‍💻');
      expect(findCollabEmoji('👨‍👩‍👧‍👦')!.native, '👨‍👩‍👧‍👦');
      expect(findCollabEmoji('🇨🇳')!.native, '🇨🇳');
      expect(findCollabEmoji('历史前缀'), isNull);
      expect(findCollabEmoji('🥟')!.matches('饺子'), isTrue);
      expect(findCollabEmoji('🥟')!.matches('DUMPLING'), isTrue);
      expect(findCollabEmoji('🚀')!.matches('huojian'), isTrue);
      expect(findCollabEmoji('🚀')!.matches('hj'), isTrue);
      expect(findCollabEmoji('💡')!.matches('灵感'), isTrue);
      expect(collabEmojiLicenses.map((notice) => notice.$1), [
        'ngx-emoji-mart',
        'Unicode CLDR',
      ]);
    },
  );

  testWidgets(
    'large catalog builds visible rows and keeps search and categories fixed',
    (tester) async {
      await tester.pumpWidget(_app(onSelected: (_) async {}));
      expect(find.byType(Tooltip).evaluate().length, lessThan(180));
      expect(find.byKey(const ValueKey('catalog-🇿🇼')), findsNothing);
      final search = find.byKey(const ValueKey('catalog-search'));
      final tabs = find.byKey(const ValueKey('catalog-categories'));
      final searchRect = tester.getRect(search);
      final tabRect = tester.getRect(tabs);
      await tester.drag(
        find.byKey(const PageStorageKey('catalog-list')),
        const Offset(0, -700),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(search), searchRect);
      expect(tester.getRect(tabs), tabRect);
      final flags = find.byKey(const ValueKey('catalog-category-flags'));
      await tester.ensureVisible(flags);
      await tester.tap(flags);
      await tester.pumpAndSettle();
      final china = find.byKey(const ValueKey('catalog-🇨🇳'));
      await tester.scrollUntilVisible(
        china,
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('catalog-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(china, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tabs locate the continuous list and manual scrolling updates only the tabs',
    (tester) async {
      var writes = 0;
      await tester.pumpWidget(
        _app(
          onSelected: (_) async {
            writes++;
          },
        ),
      );
      final list = find.byKey(const PageStorageKey('catalog-list'));
      final search = find.byKey(const ValueKey('catalog-search'));
      final initialSearch = tester.widget<TextField>(search);
      final initialList = tester.widget<ListView>(list);
      final count = initialList.childrenDelegate.estimatedChildCount;
      expect(initialList.itemExtent, isNotNull);
      final nature = find.byKey(const ValueKey('catalog-category-nature'));
      await tester.ensureVisible(nature);
      await tester.pumpAndSettle();
      await tester.tap(nature);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final tabs = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabs.controller!.index, 2, reason: '经过其他分类时仍保持点击目标');
      await tester.pumpAndSettle();
      final heading = find.byKey(const ValueKey('catalog-heading-动物与自然'));
      expect(
        tester.getTopLeft(heading).dy,
        closeTo(tester.getTopLeft(list).dy, .5),
      );
      expect(
        tester.widget<ListView>(list).childrenDelegate.estimatedChildCount,
        count,
      );
      expect(
        identical(tester.widget<TextField>(search), initialSearch),
        isTrue,
        reason: '点击及联动不重建整个目录/搜索栏',
      );
      await tester.drag(list, const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(tabs.controller!.index, 1, reason: '向上浏览前一类，同步Tab');
      expect(
        identical(tester.widget<TextField>(search), initialSearch),
        isTrue,
      );
      final people = find.byKey(const ValueKey('catalog-category-people'));
      expect(
        tester.getRect(people).overlaps(tester.getRect(find.byType(TabBar))),
        isTrue,
      );
      expect(find.byType(Tooltip).evaluate().length, lessThan(180));
      expect(writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dragging interrupts navigation and closing ignores a pending animation',
    (tester) async {
      await tester.pumpWidget(_app(onSelected: (_) async {}));
      final list = find.byKey(const PageStorageKey('catalog-list'));
      final flags = find.byKey(const ValueKey('catalog-category-flags'));
      await tester.ensureVisible(flags);
      await tester.pumpAndSettle();
      await tester.tap(flags);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      await tester.drag(list, const Offset(0, 200));
      await tester.pumpAndSettle();
      final tabs = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabs.controller!.index, isNot(8));
      final position = tester.widget<ListView>(list).controller!.offset;
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester.widget<ListView>(list).controller!.offset,
        position,
        reason: '迟到完成不得重新跳到旧目标',
      );
      await tester.ensureVisible(flags);
      await tester.pumpAndSettle();
      await tester.tap(flags);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rapid tabs and leaving search keep all categories and use the last target',
    (tester) async {
      await tester.pumpWidget(_app(onSelected: (_) async {}));
      final list = find.byKey(const PageStorageKey('catalog-list'));
      final initialCount = tester
          .widget<ListView>(list)
          .childrenDelegate
          .estimatedChildCount;
      await tester.enterText(
        find.byKey(const ValueKey('catalog-search')),
        '饺子',
      );
      await tester.pumpAndSettle();
      final objects = find.byKey(const ValueKey('catalog-category-objects'));
      await tester.ensureVisible(objects);
      await tester.pumpAndSettle();
      await tester.tap(objects);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final symbols = find.byKey(const ValueKey('catalog-category-symbols'));
      await tester.ensureVisible(symbols);
      await tester.pump();
      await tester.tap(symbols);
      await tester.pumpAndSettle();
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 7);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('catalog-search')))
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester.widget<ListView>(list).childrenDelegate.estimatedChildCount,
        initialCount,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('catalog-heading-符号'))).dy,
        closeTo(tester.getTopLeft(list).dy, .5),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'far navigation never saves a cell tapped during the fading transition',
    (tester) async {
      var writes = 0;
      await tester.pumpWidget(
        _app(
          onSelected: (_) async {
            writes++;
          },
        ),
      );
      final flags = find.byKey(const ValueKey('catalog-category-flags'));
      await tester.ensureVisible(flags);
      await tester.pumpAndSettle();
      await tester.tap(flags);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 40));
      final list = find.byKey(const PageStorageKey('catalog-list'));
      final fade = find.byKey(const ValueKey('catalog-navigation-transition'));
      expect(tester.widget<FadeTransition>(fade).opacity.value, lessThan(1));
      final viewport = tester.getRect(list);
      final visible = find.byType(InkResponse).evaluate().firstWhere((element) {
        final button = find.byWidget(element.widget);
        return viewport.contains(tester.getCenter(button));
      });
      await tester.tap(find.byWidget(visible.widget));
      await tester.pumpAndSettle();
      expect(writes, 0);
      expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 8);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Chinese search, skin selection and shared recent preserve exact Unicode',
    (tester) async {
      final selected = <String>[];
      await tester.pumpWidget(
        _app(
          onSelected: (value) async {
            selected.add(value);
          },
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('catalog-search')),
        '宇航员',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('catalog-skin-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('catalog-skin-3')));
      await tester.pumpAndSettle();
      final astronaut = find.byKey(const ValueKey('catalog-👩🏽‍🚀'));
      await tester.ensureVisible(astronaut);
      await tester.tap(astronaut);
      await tester.pumpAndSettle();
      expect(selected, ['👩🏽‍🚀']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        _app(
          onSelected: (value) async {
            selected.add(value);
          },
        ),
      );
      expect(find.text('最近使用'), findsOneWidget);
      expect(find.byKey(const ValueKey('catalog-👩🏽‍🚀')), findsOneWidget);
      // Leave the process-wide preference at its default for other widget cases.
      await tester.tap(find.byKey(const ValueKey('catalog-skin-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('catalog-skin-0')));
      await tester.pumpAndSettle();
      expect(selected, hasLength(1), reason: '肤色和分类浏览不得写文档');
    },
  );

  testWidgets(
    'saving prevents duplicate writes and late completion after disposal is safe',
    (tester) async {
      final pending = Completer<void>();
      var writes = 0;
      await tester.pumpWidget(
        _app(
          onSelected: (_) async {
            writes++;
            await pending.future;
          },
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('catalog-search')),
        '饺子',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('catalog-🥟')));
      await tester.pump();
      expect(
        tester
            .widget<InkResponse>(find.byKey(const ValueKey('catalog-🥟')))
            .onTap,
        isNull,
      );
      expect(writes, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      pending.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed emoji save remains visible and permits retry', (
    tester,
  ) async {
    var writes = 0;
    await tester.pumpWidget(
      _app(
        onSelected: (_) async {
          if (++writes == 1) throw StateError('fixture offline');
        },
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('catalog-search')), '飞碟');
    await tester.pumpAndSettle();
    final emoji = find.byKey(const ValueKey('catalog-🛸'));
    await tester.tap(emoji);
    await tester.pumpAndSettle();
    expect(find.text('表情设置失败，请重试'), findsOneWidget);
    expect(tester.widget<InkResponse>(emoji).onTap, isNotNull);
    await tester.tap(emoji);
    await tester.pumpAndSettle();
    expect(writes, 2);
    expect(tester.takeException(), isNull);
  });

  for (final (size, scale, keyboard) in [
    (const Size(390, 844), 1.0, 0.0),
    (const Size(320, 568), 2.0, 0.0),
    (const Size(390, 844), 1.0, 300.0),
    (const Size(568, 320), 1.0, 0.0),
  ]) {
    testWidgets(
      'bottom sheet keeps emoji controls reachable $size/$scale/$keyboard',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          _app(
            size: size,
            scale: scale,
            keyboard: keyboard,
            sheet: true,
            onSelected: (_) async {},
          ),
        );
        await tester.pumpAndSettle();
        final search = tester.getRect(
          find.byKey(const ValueKey('catalog-search')),
        );
        final done = tester.getRect(find.text('完成'));
        expect(search.left, greaterThanOrEqualTo(0));
        expect(search.right, lessThanOrEqualTo(size.width));
        expect(done.bottom, lessThanOrEqualTo(size.height - keyboard));
        if (keyboard == 0 && scale == 1 && size.width == 390) {
          await _capture(tester, 'browse');
        }
        await tester.enterText(
          find.byKey(const ValueKey('catalog-search')),
          '饺子',
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('catalog-🥟')), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (keyboard == 0 && scale == 1 && size.width == 390) {
          await _capture(tester, 'search');
        }
      },
    );
  }
}

/// 用[size]/[scale]/[keyboard]模拟真实约束；[sheet]为true使用公共底部外壳。
/// [onSelected]借用测试保存回调，不创建业务服务；默认固定390×420用于目录交互。
Widget _app({
  required Future<void> Function(String) onSelected,
  Size size = const Size(390, 844),
  double scale = 1,
  double keyboard = 0,
  bool sheet = false,
}) => MaterialApp(
  theme: ThemeData(
    fontFamily: Platform.environment['COLLAB_EMOJI_PREVIEW_FONT'] == null
        ? null
        : 'EmojiPreview',
    fontFamilyFallback: const ['Noto Color Emoji'],
  ),
  home: MediaQuery(
    data: MediaQueryData(
      size: size,
      textScaler: TextScaler.linear(scale),
      viewInsets: EdgeInsets.only(bottom: keyboard),
    ),
    child: Scaffold(
      body: RepaintBoundary(
        key: const ValueKey('emoji-preview'),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: sheet
              ? CollabBottomSheet(
                  title: const Text('设置表情'),
                  icon: LucideIcons.smile,
                  expand: true,
                  scrollBody: false,
                  leadingAction: TextButton(
                    onPressed: () {},
                    child: const Text('移除'),
                  ),
                  actions: [
                    FilledButton(onPressed: () {}, child: const Text('完成')),
                  ],
                  child: CollabEmojiPicker(
                    keyPrefix: 'catalog',
                    onSelected: onSelected,
                  ),
                )
              : SizedBox(
                  width: 390,
                  height: 420,
                  child: CollabEmojiPicker(
                    keyPrefix: 'catalog',
                    onSelected: onSelected,
                  ),
                ),
        ),
      ),
    ),
  ),
);

/// 仅预览时从显式环境路径加载[FontLoader]资源；普通回归不依赖本机字体。
Future<void> _loadPreviewFonts() async {
  final path = Platform.environment['COLLAB_EMOJI_PREVIEW_FONT'];
  if (path == null) return;
  final loader = FontLoader('EmojiPreview')
    ..addFont(
      Future.value(ByteData.sublistView(await File(path).readAsBytes())),
    );
  await loader.load();
  await (FontLoader('packages/lucide_icons_flutter/Lucide')..addFont(
        rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
      ))
      .load();
  final emojiPath = Platform.environment['COLLAB_EMOJI_PREVIEW_EMOJI_FONT'];
  if (emojiPath != null) {
    await (FontLoader('Noto Color Emoji')..addFont(
          Future.value(
            ByteData.sublistView(await File(emojiPath).readAsBytes()),
          ),
        ))
        .load();
  }
}

/// 在[tester]中导出[name]标识的真实Flutter面板，只有设置预览目录时执行，不作为真机截图。
Future<void> _capture(WidgetTester tester, String name) async {
  final output = Platform.environment['COLLAB_EMOJI_PREVIEW_DIR'];
  if (output == null) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('emoji-preview')),
    );
    final picture = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
      await Directory(output).create(recursive: true);
      await File(
        '$output/emoji-bottom-sheet-$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      picture.dispose();
    }
  });
}
