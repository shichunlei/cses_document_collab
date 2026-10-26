import 'dart:async';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证键盘完整动作目录、顺序、能力交集、空列表及实例切换。
void main() {
  test('toolbar configuration is frozen, ordered and rejects duplicates', () {
    final items = [EditorKeyboardToolbarItem.table, EditorKeyboardToolbarItem.blockType];
    final config = EditorConfiguration(keyboardToolbarItems: items);
    items.clear();
    expect(config.keyboardToolbarItems, hasLength(2));
    expect(() => config.keyboardToolbarItems.clear(), throwsUnsupportedError);
    expect(config.keyboardToolbarItems.first, EditorKeyboardToolbarItem.table);
    expect(
      () =>
          EditorConfiguration(keyboardToolbarItems: [EditorKeyboardToolbarItem.table, EditorKeyboardToolbarItem.table]),
      throwsArgumentError,
    );
    expect(EditorConfiguration.document.keyboardToolbarItems, EditorKeyboardToolbarItem.defaults);
  });

  const tooltips = {
    EditorKeyboardToolbarItem.addBlock: '添加块',
    EditorKeyboardToolbarItem.blockType: '块类型',
    EditorKeyboardToolbarItem.textStyle: '文字样式',
    EditorKeyboardToolbarItem.blockLayout: '对齐与缩进',
    EditorKeyboardToolbarItem.image: '插入图片',
    EditorKeyboardToolbarItem.mention: '@用户',
    EditorKeyboardToolbarItem.todoList: '待办列表',
    EditorKeyboardToolbarItem.link: '链接',
    EditorKeyboardToolbarItem.video: '视频',
    EditorKeyboardToolbarItem.attachment: '附件',
    EditorKeyboardToolbarItem.audio: '音频',
    EditorKeyboardToolbarItem.bookmark: '网页卡片',
    EditorKeyboardToolbarItem.embed: '网页嵌入',
    EditorKeyboardToolbarItem.juejin: '掘金',
    EditorKeyboardToolbarItem.figma: 'Figma',
    EditorKeyboardToolbarItem.table: '表格',
    EditorKeyboardToolbarItem.columns: '多栏布局',
    EditorKeyboardToolbarItem.callout: '高亮块',
    EditorKeyboardToolbarItem.meeting: '会议',
    EditorKeyboardToolbarItem.formula: '公式',
    EditorKeyboardToolbarItem.mermaid: '代码绘图',
    EditorKeyboardToolbarItem.inlineFormula: '行内公式',
    EditorKeyboardToolbarItem.divider: '分割线',
    EditorKeyboardToolbarItem.personCard: '人员卡片',
    EditorKeyboardToolbarItem.dateCard: '日期卡片',
    EditorKeyboardToolbarItem.weather: '天气卡片',
    EditorKeyboardToolbarItem.pageDivider: '分页符',
    EditorKeyboardToolbarItem.spreadsheet: '电子表格',
    EditorKeyboardToolbarItem.multiTable: '多维表格',
    EditorKeyboardToolbarItem.mindMap: '思维导图',
  };
  for (final item in EditorKeyboardToolbarItem.values) {
    testWidgets('keyboard toolbar only enables ${item.name}', (tester) async {
      final local = LocalEditorController(
        initialText: 'Text',
        configuration: EditorConfiguration(keyboardToolbarItems: {item}),
      );
      try {
        await _mountToolbar(tester, local);
        for (final entry in tooltips.entries) {
          expect(find.byTooltip(entry.value), entry.key == item ? findsOneWidget : findsNothing);
        }
        expect(find.byType(VerticalDivider), findsOneWidget);
        expect(find.byTooltip('收起键盘'), findsOneWidget);
        expect(
          tester.getCenter(find.byTooltip(tooltips[item]!)).dx,
          lessThan(tester.getCenter(find.byTooltip('收起键盘')).dx),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _closeMountedEditor(tester, local);
      }
    });
  }

  testWidgets('common shortcuts follow caller order while dismiss remains trailing', (tester) async {
    final local = LocalEditorController(
      initialText: 'Text',
      configuration: EditorConfiguration(
        keyboardToolbarItems: [
          EditorKeyboardToolbarItem.formula,
          EditorKeyboardToolbarItem.table,
          EditorKeyboardToolbarItem.blockType,
        ],
      ),
    );
    try {
      await _mountToolbar(tester, local);
      final formula = tester.getCenter(find.byTooltip('公式')).dx;
      final table = tester.getCenter(find.byTooltip('表格')).dx;
      final type = tester.getCenter(find.byTooltip('块类型')).dx;
      final close = tester.getCenter(find.byTooltip('收起键盘')).dx;
      expect(formula, lessThan(table));
      expect(table, lessThan(type));
      expect(type, lessThan(close));
    } finally {
      await _closeMountedEditor(tester, local);
    }
  });

  testWidgets('dismiss stays at the right edge while long menus scroll and closes the toolbar', (tester) async {
    final local = LocalEditorController(
      initialText: 'Text',
      configuration: EditorConfiguration(keyboardToolbarItems: EditorKeyboardToolbarItem.values),
    );
    try {
      await _mountToolbar(tester, local);
      final close = find.byTooltip('收起键盘');
      final before = tester.getCenter(close);
      final menus = find.descendant(
        of: find.byKey(const ValueKey('editor-mobile-toolbar')),
        matching: find.byType(ListView),
      );
      await tester.drag(menus, const Offset(-2200, 0));
      await tester.pumpAndSettle();
      expect(tester.getCenter(close), before);
      expect(find.byTooltip('思维导图'), findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(local.editorState.selection, isNull);
      expect(find.byKey(const ValueKey('editor-mobile-toolbar')), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await _closeMountedEditor(tester, local);
    }
  });

  for (final entry in {
    EditorKeyboardToolbarItem.table: 'table',
    EditorKeyboardToolbarItem.columns: 'columns',
    EditorKeyboardToolbarItem.callout: 'callout',
    EditorKeyboardToolbarItem.dateCard: 'date-card',
    EditorKeyboardToolbarItem.weather: 'weather',
    EditorKeyboardToolbarItem.pageDivider: 'page-divider',
  }.entries) {
    testWidgets('direct ${entry.key.name} inserts without more sheet and has undo', (tester) async {
      final local = LocalEditorController(
        initialText: 'Text',
        configuration: EditorConfiguration(keyboardToolbarItems: [entry.key]),
      );
      try {
        await _mountToolbar(tester, local);
        await tester.tap(find.byKey(ValueKey('editor-keyboard-${entry.key.name}')));
        await _settleAction(tester);
        expect(find.byKey(const ValueKey('editor-add-block-sheet')), findsNothing);
        expect(local.editorState.document.root.children.any((node) => node.type == entry.value), isTrue);
        local.editorState.undoManager.undo();
        await tester.pumpAndSettle();
        expect(local.editorState.document.root.children.any((node) => node.type == entry.value), isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        await _closeMountedEditor(tester, local);
      }
    });
  }

  testWidgets('direct formula cancellation and creation share the original input sheet', (tester) async {
    final local = LocalEditorController(
      initialText: 'Text',
      configuration: EditorConfiguration(keyboardToolbarItems: [EditorKeyboardToolbarItem.formula]),
    );
    try {
      await _mountToolbar(tester, local);
      final before = local.editorState.document.toJson();
      await tester.tap(find.byTooltip('公式'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-add-block-sheet')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('formula-input')), 'x+y');
      await tester.tap(find.text('取消'));
      await _settleAction(tester);
      expect(local.editorState.document.toJson(), before);
      await tester.tap(find.byTooltip('公式'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('formula-input')), 'x+y');
      await tester.tap(find.byKey(const ValueKey('formula-save')));
      await _settleAction(tester);
      expect(local.editorState.document.root.children.any((node) => node.type == 'formula'), isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await _closeMountedEditor(tester, local);
    }
  });

  testWidgets('direct link uses existing source validation and inserts a link block', (tester) async {
    final local = LocalEditorController(
      initialText: 'Text',
      configuration: EditorConfiguration(keyboardToolbarItems: [EditorKeyboardToolbarItem.link]),
    );
    try {
      await _mountToolbar(tester, local);
      await tester.tap(find.byTooltip('链接'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('editor-url-block-input')), 'https://example.test/reference');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-url-block-submit')));
      await _settleAction(tester);
      expect(local.editorState.document.root.children.any((node) => node.type == 'link'), isTrue);
      expect(find.byKey(const ValueKey('editor-add-block-sheet')), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await _closeMountedEditor(tester, local);
    }
  });

  for (final revoke in [false, true]) {
    testWidgets('direct meeting respects injected picker and revocation: $revoke', (tester) async {
      final pending = Completer<CollabMeetingReference?>();
      var requests = 0;
      final local = LocalEditorController(
        initialText: 'Text',
        configuration: EditorConfiguration(keyboardToolbarItems: [EditorKeyboardToolbarItem.meeting]),
        services: CollabHostServices(
          pickMeetingReference: (_, {required canEdit}) {
            requests++;
            return pending.future;
          },
        ),
      );
      try {
        await _mountToolbar(tester, local);
        await tester.tap(find.byTooltip('会议'));
        await tester.pump();
        expect(requests, 1);
        if (revoke) {
          local.editorState.editable = false;
          local.editorState.editable = true;
        }
        pending.complete(const CollabMeetingReference(meetingId: 'fixture-meeting', title: 'Fixture'));
        await _settleAction(tester);
        expect(local.editorState.document.root.children.any((node) => node.type == 'meeting'), !revoke);
        expect(tester.takeException(), isNull);
      } finally {
        await _closeMountedEditor(tester, local);
      }
    });
  }

  for (final revoke in [false, true]) {
    testWidgets('weather creation freezes one insertion and ignores revoked query: $revoke', (tester) async {
      final pending = Completer<CollabWeatherData>();
      final local = LocalEditorController(
        initialText: 'Text',
        configuration: EditorConfiguration(keyboardToolbarItems: [EditorKeyboardToolbarItem.weather]),
        services: CollabHostServices(
          loadWeather: ({date, required refresh, required cancelled}) {
            expect(date, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
            expect(refresh, isFalse);
            return pending.future;
          },
        ),
      );
      try {
        await _mountToolbar(tester, local);
        await tester.tap(find.byTooltip('天气卡片'));
        await tester.pump();
        if (revoke) {
          local.editorState.editable = false;
          local.editorState.editable = true;
        }
        pending.complete(const CollabWeatherData(temp: 18, condition: '晴', location: '北京'));
        await _settleAction(tester);
        final cards = local.editorState.document.root.children.where((node) => node.type == 'weather');
        expect(cards.isNotEmpty, !revoke);
        if (!revoke) {
          final props = jsonDecode((cards.single.attributes['cses_resource'] as Map)['properties'] as String) as Map;
          expect(props['frozen']['temp'], 18);
          local.editorState.undoManager.undo();
          await tester.pumpAndSettle();
          expect(local.editorState.document.root.children.any((node) => node.type == 'weather'), isFalse);
          expect(local.editorState.undoManager.undoStack, isEmpty);
        }
      } finally {
        await _closeMountedEditor(tester, local);
      }
    });
  }

  for (final revoke in [false, true]) {
    testWidgets('person-card creation freezes one insertion and ignores revoked query: $revoke', (tester) async {
      final pending = Completer<CollabPersonCardData>();
      final local = LocalEditorController(
        initialText: 'Text',
        configuration: EditorConfiguration(keyboardToolbarItems: [EditorKeyboardToolbarItem.personCard]),
        services: CollabHostServices(
          loadPersonCardCreator: () {
            return pending.future;
          },
        ),
      );
      try {
        await _mountToolbar(tester, local);
        await tester.tap(find.byTooltip('人员卡片'));
        await tester.pump();
        if (revoke) {
          local.editorState.editable = false;
          local.editorState.editable = true;
        }
        pending.complete(const CollabPersonCardData(name: '张三', pinyin: 'ZHANG SAN'));
        await _settleAction(tester);
        final cards = local.editorState.document.root.children.where((node) => node.type == 'person-card');
        expect(cards.isNotEmpty, !revoke);
        if (!revoke) {
          final props = jsonDecode((cards.single.attributes['cses_resource'] as Map)['properties'] as String) as Map;
          expect(jsonDecode(props['person'])['name'], '张三');
          local.editorState.undoManager.undo();
          await tester.pumpAndSettle();
          expect(local.editorState.document.root.children.any((node) => node.type == 'person-card'), isFalse);
          expect(local.editorState.undoManager.undoStack, isEmpty);
        }
      } finally {
        await _closeMountedEditor(tester, local);
      }
    });
  }

  testWidgets('unimplemented common action only reports its existing placeholder', (tester) async {
    final local = LocalEditorController(
      initialText: 'Text',
      configuration: EditorConfiguration(keyboardToolbarItems: [EditorKeyboardToolbarItem.spreadsheet]),
    );
    try {
      await _mountToolbar(tester, local);
      final before = local.editorState.document.toJson();
      await tester.tap(find.byTooltip('电子表格'));
      await tester.pump();
      expect(find.text('电子表格 暂未支持'), findsOneWidget);
      await _settleAction(tester);
      expect(local.editorState.document.toJson(), before);
      expect(tester.takeException(), isNull);
    } finally {
      await _closeMountedEditor(tester, local);
    }
  });

  for (final limited in [false, true]) {
    testWidgets('heading menus and commands stop at H6 with limited config: $limited', (tester) async {
      final local = LocalEditorController(
        initialText: 'Legacy heading',
        configuration: limited
            ? EditorConfiguration(blocks: [EditorBlock.paragraph, EditorBlock.heading], headingLevels: {1, 6})
            : EditorConfiguration(),
      );
      try {
        await _mountToolbar(tester, local);
        await local.convert('heading', level: 6);
        await tester.pumpAndSettle();
        final before = local.editorState.document.toJson();
        await tester.tap(find.byTooltip('块类型'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('editor-block-heading-6')), findsOneWidget);
        for (final level in [7, 8, 9]) {
          expect(find.byKey(ValueKey('editor-block-heading-$level')), findsNothing);
        }
        await tester.tap(find.byTooltip('添加块'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('editor-shortcut-heading-6')), findsOneWidget);
        for (final level in [7, 8, 9]) {
          expect(find.byKey(ValueKey('editor-shortcut-heading-$level')), findsNothing);
        }
        await tester.tap(find.byKey(const ValueKey('editor-add-block-close')));
        await _settleAction(tester);
        expect(local.editorState.document.toJson(), before);
        expect(local.editorState.document.first!.attributes['level'], 6);
        expect(tester.takeException(), isNull);
      } finally {
        await _closeMountedEditor(tester, local);
      }
    });
  }

  testWidgets('empty toolbar keeps document editing and removes its row', (tester) async {
    final local = LocalEditorController(
      initialText: 'Text',
      configuration: EditorConfiguration(keyboardToolbarItems: const []),
    );
    try {
      await _mountToolbar(tester, local);
      expect(find.byKey(const ValueKey('editor-mobile-toolbar')), findsNothing);
      expect(find.byTooltip('收起键盘'), findsNothing);
      await local.convert('heading', level: 3);
      await tester.pumpAndSettle();
      expect(local.editorState.document.root.children.single.type, 'heading');
      expect(tester.takeException(), isNull);
    } finally {
      await _closeMountedEditor(tester, local);
    }
  });

  testWidgets('menu choices cannot reenable disabled block and format capabilities', (tester) async {
    final local = LocalEditorController(
      initialText: 'Text',
      configuration: EditorConfiguration(
        blocks: [EditorBlock.paragraph],
        inlineFormats: const [],
        alignments: const [],
        nextParagraphStyle: false,
        keyboardToolbarItems: {
          EditorKeyboardToolbarItem.textStyle,
          EditorKeyboardToolbarItem.image,
          EditorKeyboardToolbarItem.mention,
          EditorKeyboardToolbarItem.todoList,
          EditorKeyboardToolbarItem.blockLayout,
        },
      ),
    );
    try {
      await _mountToolbar(tester, local);
      expect(find.byKey(const ValueKey('editor-mobile-toolbar')), findsNothing);
      expect(find.byTooltip('收起键盘'), findsNothing);
      expect(local.configuration.allowsBlock('image'), isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await _closeMountedEditor(tester, local);
    }
  });

  testWidgets('switching editor instances clears a previously open menu', (tester) async {
    final first = LocalEditorController(initialText: 'First');
    final second = LocalEditorController(
      initialText: 'Second',
      configuration: EditorConfiguration(keyboardToolbarItems: [EditorKeyboardToolbarItem.table]),
    );
    try {
      await _mountToolbar(tester, first);
      await tester.tap(find.byTooltip('文字样式'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-toolbar-popup')), findsOneWidget);
      await _mountToolbar(tester, second);
      expect(find.byKey(const ValueKey('editor-toolbar-popup')), findsNothing);
      expect(find.byTooltip('文字样式'), findsNothing);
      expect(find.byTooltip('表格'), findsOneWidget);
      expect(find.byTooltip('收起键盘'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await _closeMountedEditor(tester, second);
      await tester.runAsync(first.close);
    }
  });

  for (final showAdd in [false, true]) {
    testWidgets('keyboard add button visibility: $showAdd', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final local = LocalEditorController(
        initialText: 'Text',
        configuration: showAdd
            ? null
            : EditorConfiguration(
                keyboardToolbarItems: EditorKeyboardToolbarItem.defaults.where(
                  (item) => item != EditorKeyboardToolbarItem.addBlock,
                ),
              ),
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              AppFlowyEditorLocalizations.delegate,
            ],
            home: Scaffold(body: DocumentEditorView(editorState: local.editorState)),
          ),
        );
        final state = local.editorState;
        state.selection = Selection.collapsed(Position(path: [0], offset: 4));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('editor-shortcut-add')), showAdd ? findsOneWidget : findsNothing);
        expect(find.byTooltip('添加块'), showAdd ? findsOneWidget : findsNothing);
        expect(find.byTooltip('块类型'), findsOneWidget);
        expect(find.byTooltip('文字样式'), findsOneWidget);
        expect(find.byTooltip('插入图片'), findsOneWidget);
        expect(local.configuration.allowsBlock('table'), isTrue);
        await local.convert('heading', level: 3);
        await tester.pumpAndSettle();
        expect(state.document.root.children.single.type, 'heading');
        expect(state.document.root.children.single.attributes['level'], 3);
        expect(EditorConfiguration.document.keyboardToolbarItems.contains(EditorKeyboardToolbarItem.addBlock), isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        local.editorState.selection = null;
        await tester.pumpWidget(const SizedBox.shrink());
        tester.testTextInput.unregister();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.runAsync(local.close);
      }
    });
  }
}

/// 为[local]挂载公开正文视图；[tester]拥有测试画布与键盘边距，结束时由测试框架恢复。
Future<void> _mountToolbar(WidgetTester tester, LocalEditorController local) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  tester.view.devicePixelRatio = 1;
  tester.view.viewInsets = const FakeViewPadding(bottom: 260);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        AppFlowyEditorLocalizations.delegate,
      ],
      home: Scaffold(body: DocumentEditorView(editorState: local.editorState)),
    ),
  );
  local.editorState.selection = Selection.collapsed(Position(path: [0]));
  await tester.pumpAndSettle();
}

/// 先用[tester]卸载视图并清理测试输入连接，再关闭测试创建的[local]。
Future<void> _closeMountedEditor(WidgetTester tester, LocalEditorController local) async {
  local.editorState.selection = null;
  await tester.pumpWidget(const SizedBox.shrink());
  tester.testTextInput.unregister();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.runAsync(local.close);
}

/// 用[tester]等待完整模态退场和键盘恢复，避免将迟到的恢复任务留给下一用例。
Future<void> _settleAction(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}
