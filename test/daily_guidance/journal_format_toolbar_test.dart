import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_store.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_page.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_ruled_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 使用真实草稿校验和JSON往返，不访问用户文件。
class _Store implements JournalStore {
  /// [kind]可为业务行种类，null使用普通正文。
  _Store({String? kind}) {
    final blank = JournalDraft.blank(DateTime(2026, 10, 23));
    final document = Document(
      root: Node(
        type: 'page',
        children: [
          Node(
            type: journalSectionType,
            attributes: {'section': 'record'},
            children: [
              paragraphNode(
                text: 'ABCDE',
                attributes: {
                  if (kind != null) ...{
                    'guidance_entry': kind,
                    'guidance_entry_id': 'format-business',
                    'guidance_done': false,
                  },
                },
              ),
              paragraphNode(text: 'Neighbor'),
            ],
          ),
        ],
      ),
    );
    try {
      value = JournalDraft.fromJson({
        ...blank.toJson(),
        'document': document.toJson(),
      });
    } finally {
      document.dispose();
    }
  }

  /// 最近已校验的独立持久化快照。
  late JournalDraft value;

  /// 恢复副本，模拟退出后重新读取。
  @override
  Future<JournalDraft?> read() async => JournalDraft.fromJson(value.toJson());

  /// 保存[draft]的JSON往返副本。
  @override
  Future<void> write(JournalDraft draft) async =>
      value = JournalDraft.fromJson(draft.toJson());
}

/// 在[tester]中构建路由，借用[store]；[width]/[scale]模拟屏宽与系统字号。
Future<EditorState> _open(
  WidgetTester tester,
  _Store store, {
  double width = 390,
  double scale = 1,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  tester.view.devicePixelRatio = 1;
  tester.view.viewInsets = const FakeViewPadding(bottom: 260);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              await Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => LocalJournalPage(store: store),
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  final state = _state(tester);
  state.selection = Selection.single(
    path: [0, 0],
    startOffset: 0,
    endOffset: 5,
  );
  await tester.pumpAndSettle();
  return state;
}

/// 从[tester]借用当前视图的编辑状态，不负责释放。
EditorState _state(WidgetTester tester) =>
    tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;

/// 打开[tester]内指定[tooltip]的菜单；[menu]已打开时保留同一会话。
Future<void> _menu(WidgetTester tester, String tooltip, String menu) async {
  if (find.byKey(ValueKey(menu)).evaluate().isEmpty) {
    await tester.tap(find.byTooltip(tooltip));
    await tester.pumpAndSettle();
  }
}

/// 在[tester]的横向[menu]中滚动并点击[action]，覆盖菜单新增项目后的实际可达性。
Future<void> _tap(WidgetTester tester, String menu, String action) async {
  final target = find.byKey(ValueKey(action));
  for (final direction in [-1.0, 1.0]) {
    for (var i = 0; i < 14 && target.hitTestable().evaluate().isEmpty; i++) {
      await tester.drag(find.byKey(ValueKey(menu)), Offset(direction * 130, 0));
      await tester.pumpAndSettle();
    }
  }
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// 读取[tester]中ABCDE正文的真实渲染对象，忽略工具栏与标题。
RenderParagraph _paragraph(WidgetTester tester) => tester
    .renderObjectList<RenderParagraph>(find.byType(RichText))
    .singleWhere((paragraph) => paragraph.text.toPlainText().contains('ABCDE'));

/// 将借用的[span]展平到文本片段，保留逐层继承后的真实样式。
Iterable<TextSpan> _spans(InlineSpan span) sync* {
  if (span is! TextSpan) return;
  if (span.text?.contains('ABCDE') == true) yield span;
  for (final child in span.children ?? const <InlineSpan>[]) {
    yield* _spans(child);
  }
}

/// 获取[tester]中正文横格的局部纵坐标，不受预览工具栏高度影响。
List<double> _rules(WidgetTester tester) => tester
    .renderObjectList<RenderJournalRules>(find.byType(JournalRuledContent))
    .expand((rules) => rules.debugLineOffsets)
    .toList();

/// 保存并退出[tester]中的路由，再通过同一存储重开，返回新的借用会话。
Future<EditorState> _reopen(WidgetTester tester) async {
  // StreamSubscription.cancel 可返回根Zone创建的已完成Future，需给真实事件循环完成机会。
  await tester.runAsync(() async {
    await Future<void>.delayed(Duration.zero);
  });
  await tester.pumpAndSettle();
  expect(
    _state(tester).editable,
    isTrue,
    reason: 'return to editing before leaving',
  );
  expect(
    tester
        .widget<TextButton>(find.byKey(const ValueKey('journal-preview')))
        .onPressed,
    isNotNull,
    reason: 'preview switch completed',
  );
  await tester.tap(find.byKey(const ValueKey('journal-back')));
  await tester.pumpAndSettle();
  expect(find.byType(LocalJournalPage), findsNothing);
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return _state(tester);
}

/// 覆盖真实菜单、渲染、撤销、预览及保存重开，不以入口存在代替功能生效。
void main() {
  for (final sample in [(320.0, 1.0), (390.0, 2.0)]) {
    testWidgets('H1-H6 render and survive preview/reopen at $sample', (
      tester,
    ) async {
      final store = _Store();
      final state = await _open(
        tester,
        store,
        width: sample.$1,
        scale: sample.$2,
      );
      final neighbor = state.getNodeAtPath([0, 1])!.toJson();
      await _menu(tester, '块类型', 'editor-block-style-menu');
      for (final level in [4, 5, 6]) {
        expect(
          find.byKey(ValueKey('editor-block-heading-$level')),
          findsNothing,
        );
      }
      for (var level = 1; level <= 6; level++) {
        await _tap(
          tester,
          'editor-block-style-menu',
          'editor-block-heading-$level',
        );
        final visibleLimit = level < 3 ? 3 : (level + 1).clamp(3, 6);
        if (level >= 3 && level < 6) {
          expect(
            find.byKey(ValueKey('editor-block-heading-${level + 1}')),
            findsOneWidget,
          );
        }
        for (var heading = visibleLimit + 1; heading <= 6; heading++) {
          expect(
            find.byKey(ValueKey('editor-block-heading-$heading')),
            findsNothing,
          );
        }
        final node = state.getNodeAtPath([0, 0])!;
        expect(node.type, HeadingBlockKeys.type);
        expect(node.attributes[HeadingBlockKeys.level], level);
        expect(node.delta!.toPlainText(), 'ABCDE');
        expect(_paragraph(tester).text.toPlainText(), contains('ABCDE'));
        final sizes = _spans(
          _paragraph(tester).text,
        ).map((s) => s.style?.fontSize).whereType<double>().toList();
        expect(sizes, isNotEmpty);
        expect(
          sizes.first,
          closeTo(16 * [2.0, 1.8, 1.6, 1.4, 1.0, 1.0][level - 1], .01),
        );
      }
      expect(state.getNodeAtPath([0, 1])!.toJson(), neighbor);
      await tester.tap(find.byTooltip('撤销'));
      await tester.pumpAndSettle();
      expect(state.getNodeAtPath([0, 0])!.attributes['level'], 5);
      await tester.tap(find.byTooltip('重做'));
      await tester.pumpAndSettle();
      final rules = _rules(tester);
      await tester.tap(find.byKey(const ValueKey('journal-preview')));
      await tester.pumpAndSettle();
      expect(_rules(tester), rules);
      expect(find.byKey(const ValueKey('editor-mobile-toolbar')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('journal-preview')));
      await tester.pumpAndSettle();
      final reopened = await _reopen(tester);
      expect(reopened.getNodeAtPath([0, 0])!.attributes['level'], 6);
      reopened.selection = Selection.collapsed(
        Position(path: [0, 0], offset: 2),
      );
      await tester.pumpAndSettle();
      await _menu(tester, '块类型', 'editor-block-style-menu');
      await tester.drag(
        find.byKey(const ValueKey('editor-block-style-menu')),
        const Offset(-500, 0),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('editor-block-heading-6')),
        findsOneWidget,
      );
      reopened.selection = Selection.collapsed(
        Position(path: [0, 1], offset: 2),
      );
      await tester.pumpAndSettle();
      for (final level in [4, 5, 6]) {
        expect(
          find.byKey(ValueKey('editor-block-heading-$level')),
          findsNothing,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('text/background colors, code and scripts render and persist', (
    tester,
  ) async {
    final store = _Store();
    final state = await _open(tester, store);
    await _menu(tester, '文字样式', 'editor-inline-style-menu');
    await _tap(tester, 'editor-inline-style-menu', 'editor-inline-code');
    await _tap(tester, 'editor-inline-style-menu', 'editor-inline-text-color');
    await _tap(tester, 'editor-text-color-menu', 'editor-text-color-blue');
    await _tap(tester, 'editor-text-color-menu', 'editor-text-color-back');
    await _tap(
      tester,
      'editor-inline-style-menu',
      'editor-inline-background-color',
    );
    await _tap(
      tester,
      'editor-background-color-menu',
      'editor-background-color-yellow',
    );
    await _tap(
      tester,
      'editor-background-color-menu',
      'editor-background-color-back',
    );
    await _tap(tester, 'editor-inline-style-menu', 'editor-inline-superscript');
    expect(
      state.getNodeAtPath([0, 0])!.delta!.first.attributes?['cses_superscript'],
      isTrue,
    );
    expect(
      _spans(_paragraph(tester).text).first.style!.fontFeatures!.single.feature,
      'sups',
    );
    await _tap(tester, 'editor-inline-style-menu', 'editor-inline-subscript');
    final attrs = state.getNodeAtPath([0, 0])!.delta!.first.attributes!;
    expect(attrs['cses_superscript'], isNull);
    expect(attrs['cses_subscript'], isTrue);
    expect(attrs[AppFlowyRichTextKeys.textColor], '0xff0b6e99');
    expect(attrs[AppFlowyRichTextKeys.backgroundColor], '0xfffbf3db');
    final style = _spans(_paragraph(tester).text).first.style!;
    expect(style.color, const Color(0xff0b6e99));
    expect(style.backgroundColor, const Color(0xfffbf3db));
    expect(style.fontFamily, 'monospace');
    expect(style.fontFeatures!.single.feature, 'subs');
    final snapshot = state.document.toJson();
    await tester.pump(const Duration(seconds: 1));
    expect(store.value.documentJson, jsonEncode(snapshot));
    await tester.tap(find.byKey(const ValueKey('journal-preview')));
    await tester.pumpAndSettle();
    expect(_spans(_paragraph(tester).text).first.style, style);
    await tester.tap(find.byKey(const ValueKey('journal-preview')));
    await tester.pumpAndSettle();
    expect((await _reopen(tester)).document.toJson(), snapshot);
    expect(_spans(_paragraph(tester).text).first.style, style);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('font size uses real selection and keeps list marker centered', (
    tester,
  ) async {
    final store = _Store();
    final state = await _open(tester, store);
    await _menu(tester, '块类型', 'editor-block-style-menu');
    await _tap(tester, 'editor-block-style-menu', 'editor-block-todo_list-0');
    await _menu(tester, '文字样式', 'editor-inline-style-menu');
    await _tap(tester, 'editor-inline-style-menu', 'editor-inline-font-size');
    final choice = find.byKey(const ValueKey('editor-font-size-24'));
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.pumpAndSettle();
    expect(state.getNodeAtPath([0, 0])!.delta!.first.attributes?['t:px'], 24);
    expect(_spans(_paragraph(tester).text).first.style!.fontSize, 24);
    final marker = find.byKey(
      ValueKey('journal-list-marker-${state.getNodeAtPath([0, 0])!.id}'),
    );
    expect(tester.getSize(marker).height, 48);
    final snapshot = state.document.toJson();
    expect((await _reopen(tester)).document.toJson(), snapshot);
    expect(_spans(_paragraph(tester).text).first.style!.fontSize, 24);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  test('malformed/unsupported persisted heading levels are rejected', () {
    for (final level in [null, '1', 0, 7, 10]) {
      final store = _Store();
      final document = Document.fromJson(jsonDecode(store.value.documentJson));
      try {
        final root = Node(
          type: 'page',
          children: [
            Node(
              type: journalSectionType,
              attributes: {'section': 'record'},
              children: [
                Node(
                  type: HeadingBlockKeys.type,
                  attributes: {
                    blockComponentDelta: (Delta()..insert('corrupt')).toJson(),
                    HeadingBlockKeys.level: ?level,
                  },
                ),
              ],
            ),
          ],
        );
        final invalid = Document(root: root);
        try {
          expect(
            () => JournalDraft.fromJson({
              ...store.value.toJson(),
              'document': invalid.toJson(),
            }),
            throwsFormatException,
          );
        } finally {
          invalid.dispose();
        }
      } finally {
        document.dispose();
      }
    }
  });

  for (final type in [
    'paragraph',
    'heading',
    'bulleted_list',
    'numbered_list',
    'todo_list',
  ]) {
    testWidgets('$type alignment and flat indent preserve business identity', (
      tester,
    ) async {
      final store = _Store(kind: 'help');
      final state = await _open(tester, store);
      if (type != 'paragraph') {
        await _menu(tester, '块类型', 'editor-block-style-menu');
        await _tap(
          tester,
          'editor-block-style-menu',
          'editor-block-$type-${type == 'heading' ? 2 : 0}',
        );
      }
      final node = state.getNodeAtPath([0, 0])!;
      expect(node.attributes['guidance_entry_id'], 'format-business');
      expect(find.text('都来帮'), findsOneWidget);
      await _menu(tester, '对齐与缩进', 'editor-block-layout-menu');
      final initialX = _paragraph(tester).localToGlobal(Offset.zero).dx;
      await _tap(tester, 'editor-block-layout-menu', 'editor-block-indent');
      expect(
        _paragraph(tester).localToGlobal(Offset.zero).dx,
        greaterThan(initialX),
      );
      expect(state.getNodeAtPath([0, 0])!.children, isEmpty);
      for (final alignment in [
        'center',
        'right',
        'justify',
        'distributed',
        'left',
      ]) {
        await _tap(
          tester,
          'editor-block-layout-menu',
          'editor-block-align-$alignment',
        );
        expect(
          state.getNodeAtPath([0, 0])!.attributes[blockComponentAlign],
          alignment,
        );
        expect(
          _paragraph(tester).textAlign,
          alignment == 'center'
              ? TextAlign.center
              : alignment == 'right'
              ? TextAlign.right
              : alignment == 'left'
              ? TextAlign.left
              : TextAlign.justify,
        );
        expect(find.text('都来帮'), findsOneWidget);
      }
      await _tap(tester, 'editor-block-layout-menu', 'editor-block-outdent');
      expect(state.getNodeAtPath([0, 0])!.type, type);
      await _tap(
        tester,
        'editor-block-layout-menu',
        'editor-block-background-color',
      );
      await _tap(
        tester,
        'editor-block-background-color-menu',
        'editor-block-background-color-yellow',
      );
      expect(
        state.getNodeAtPath([0, 0])!.attributes[blockComponentBackgroundColor],
        isNotNull,
      );
      final snapshot = state.document.toJson();
      expect((await _reopen(tester)).document.toJson(), snapshot);
      expect(find.text('都来帮'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
