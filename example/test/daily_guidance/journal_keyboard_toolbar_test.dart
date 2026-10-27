import 'dart:io';
import 'dart:ui' as ui;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_store.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 独立往返快照存储；不访问真实账号、文件或网络。
class _Store implements JournalStore {
  /// 最近成功保存的草稿，初始仅有今日记录。
  JournalDraft value = JournalDraft.blank(DateTime(2026, 10, 22));

  /// 返回独立恢复值，避免编辑树共享。
  @override
  Future<JournalDraft?> read() async => JournalDraft.fromJson(value.toJson());

  /// 对[draft]执行真实草稿校验后保存。
  @override
  Future<void> write(JournalDraft draft) async =>
      value = JournalDraft.fromJson(draft.toJson());
}

/// 原生提及目录固定返回虚构人员，不依赖组织或认证接口。
class _MentionDirectory implements CollabMentionDirectory {
  /// 搜索[keyword]时返回虚构匹配项。
  @override
  Future<List<CollabMentionUser>> search(String keyword) async => const [
    CollabMentionUser(id: 'toolbar-user', name: '测试同事', avatarUrl: ''),
  ];

  /// 本用例不加载详情；借用[userId]不产生网络请求。
  @override
  Future<CollabMentionUser?> load(String userId) async => null;
}

/// 用[store]构建可正常返回保存的路由，[scale]控制系统字号。
Widget _app(_Store store, double scale) => MaterialApp(
  theme: ThemeData(fontFamily: 'ToolbarPreview'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () async {
          await Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => LocalJournalPage(
                store: store,
                mentionDirectory: _MentionDirectory(),
              ),
            ),
          );
        },
        child: const Text('打开'),
      ),
    ),
  ),
);

/// 在[tester]中打开[store]对应页面；[width]为逻辑宽度，[scale]为字号倍率。
Future<EditorState> _open(
  WidgetTester tester,
  _Store store, {
  double width = 390,
  double scale = 1,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  tester.view.devicePixelRatio = 1;
  tester.view.viewInsets = const FakeViewPadding(bottom: 260);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(_app(store, scale));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  final state = tester
      .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
      .editorState;
  state.selection = Selection.collapsed(Position(path: [0, 0]));
  await tester.pumpAndSettle();
  return state;
}

/// 在[tester]里找到工具栏自己的横向列表，不匹配正文滚动区。
Finder _toolbarList(WidgetTester tester) => find.descendant(
  of: find.byKey(const ValueKey('editor-mobile-toolbar')),
  matching: find.byType(ListView),
);

/// 横向移动[tester]中的工具栏直到[target]可点击，拒绝静默忽略不可达入口。
Future<void> _reveal(WidgetTester tester, Finder target) async {
  for (var i = 0; i < 12 && target.hitTestable().evaluate().isEmpty; i++) {
    await tester.drag(_toolbarList(tester), const Offset(-140, 0));
    await tester.pumpAndSettle();
  }
  expect(target.hitTestable(), findsOneWidget);
}

/// 可选地导出[tester]当前工具栏；[name]为固定测试名，只包含虚构内容。
Future<void> _capture(WidgetTester tester, String name) async {
  final output = Platform.environment['KEYBOARD_TOOLBAR_PREVIEW_DIR'];
  if (output == null || output.isEmpty) return;
  final element = find
      .byKey(const ValueKey('editor-mobile-toolbar'))
      .evaluate()
      .single;
  RenderObject? object = element.renderObject;
  while (object != null && object is! RenderRepaintBoundary) {
    object = object.parent;
  }
  expect(object, isA<RenderRepaintBoundary>());
  if (object is! RenderRepaintBoundary) return;
  final boundary = object;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      await Directory(output).create(recursive: true);
      await File('$output/$name.png').writeAsBytes(bytes);
    } finally {
      image.dispose();
    }
  });
}

/// 完整页面验证原生入口、自定义动作、窄屏滚动和预览隔离。
void main() {
  setUpAll(() async {
    final font = Platform.environment['KEYBOARD_TOOLBAR_PREVIEW_FONT'];
    if (font != null && font.isNotEmpty) {
      await (FontLoader('packages/lucide_icons_flutter/Lucide')..addFont(
            rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
          ))
          .load();
      final bytes = await File(font).readAsBytes();
      await (FontLoader(
        'ToolbarPreview',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
  });

  for (final sample in [(320.0, 1.0), (390.0, 2.0)]) {
    testWidgets('toolbar is reachable at ${sample.$1}/${sample.$2}', (
      tester,
    ) async {
      await _open(tester, _Store(), width: sample.$1, scale: sample.$2);
      final close = find.byTooltip('收起键盘');
      final before = tester.getCenter(close);
      expect(find.byTooltip('@用户'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('editor-keyboard-todoList')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('guidance-action-task')), findsNothing);
      await _capture(tester, 'toolbar-${sample.$1.toInt()}-start');
      final selfCheck = find.byKey(
        const ValueKey('editor-keyboard-host-guidance-add-self-check'),
      );
      await _reveal(tester, selfCheck);
      expect(tester.getCenter(close), before);
      await _capture(tester, 'toolbar-${sample.$1.toInt()}-end');
      await tester.tap(selfCheck);
      await tester.pumpAndSettle();
      final state = tester
          .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
          .editorState;
      expect(
        state.document.root.children.where(
          (n) => n.attributes['section'] == 'self-check',
        ),
        hasLength(1),
      );
      expect(
        find.byKey(
          const ValueKey('editor-keyboard-host-guidance-add-self-check'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('journal-back')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  for (final kind in ['pilot', 'help']) {
    testWidgets('$kind native picker cancel resumes input without writing', (
      tester,
    ) async {
      final state = await _open(tester, _Store());
      final before = state.document.toJson();
      final action = find.byKey(
        ValueKey('editor-keyboard-host-guidance-action-$kind'),
      );
      await _reveal(tester, action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(state.localTransactionsPaused, isTrue);
      await state.apply(
        state.transaction..insertText(state.getNodeAtPath([0, 0])!, 0, '迟到输入'),
      );
      expect(state.document.toJson(), before);
      await tester.tap(find.byKey(const ValueKey('mention-close')));
      await tester.pumpAndSettle();
      expect(state.document.toJson(), before);
      expect(state.localTransactionsPaused, isFalse);
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.tap(find.byKey(const ValueKey('journal-back')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('$kind native picker rejects account round trips', (
      tester,
    ) async {
      final cookie = ctx.cookieId;
      addTearDown(() => ctx.cookieId = cookie);
      final state = await _open(tester, _Store());
      final before = state.document.toJson();
      final action = find.byKey(
        ValueKey('editor-keyboard-host-guidance-action-$kind'),
      );
      await _reveal(tester, action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      ctx.cookieId = 'business-other-session';
      await tester.pump(const Duration(milliseconds: 450));
      ctx.cookieId = cookie;
      await tester.pump();
      expect(
        find.byKey(const ValueKey('mention-user-toolbar-user')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('mention-close')));
      await tester.pumpAndSettle();
      expect(state.document.toJson(), before);
      expect(state.localTransactionsPaused, isFalse);
      expect(state.editable, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(find.byKey(const ValueKey('journal-back')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('custom $kind action preserves source and resumes input', (
      tester,
    ) async {
      final state = await _open(tester, _Store());
      await state.apply(
        state.transaction..insertText(state.getNodeAtPath([0, 0])!, 0, '记录'),
      );
      state.selection = Selection.collapsed(Position(path: [0, 0], offset: 2));
      await tester.pumpAndSettle();
      final action = find.byKey(
        ValueKey('editor-keyboard-host-guidance-action-$kind'),
      );
      await _reveal(tester, action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.text('选择用户和部门'), findsNothing);
      expect(state.localTransactionsPaused, isTrue);
      await tester.tap(find.byKey(const ValueKey('mention-user-toolbar-user')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(state.getNodeAtPath([0, 0])!.delta!.toPlainText(), '记录');
      final business = state.getNodeAtPath([0, 1])!;
      expect(business.attributes['guidance_entry'], kind);
      expect(business.delta!.toPlainText(), '\uFFFC ');
      final mention = business.delta!.whereType<TextInsert>().first;
      expect(EditorUserMention.read(mention.attributes!).id, 'toolbar-user');
      expect(mention.attributes!.containsKey('guidance_mention'), isFalse);
      expect(state.localTransactionsPaused, isFalse);
      expect(state.selection?.start.path, [0, 1]);
      expect(state.editable, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('journal-back')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('native picker cannot restore input after account changes', (
    tester,
  ) async {
    final cookie = ctx.cookieId;
    addTearDown(() => ctx.cookieId = cookie);
    final state = await _open(tester, _Store());
    await state.apply(
      state.transaction..insertText(state.getNodeAtPath([0, 0])!, 0, '记录'),
    );
    state.selection = Selection.collapsed(Position(path: [0, 0], offset: 2));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('@用户'));
    await tester.pumpAndSettle();
    ctx.cookieId = 'toolbar-other-session';
    await tester.tap(find.byKey(const ValueKey('mention-user-toolbar-user')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(state.getNodeAtPath([0, 0])!.delta!.toPlainText(), '记录');
    expect(state.editable, isFalse);
    expect(find.byKey(const ValueKey('editor-mobile-toolbar')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('journal-back')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final identity in ['cookie', 'user', 'company']) {
    testWidgets(
      'review regression: native picker revokes a changed $identity permanently',
      (tester) async {
        final originalCookie = ctx.cookieId;
        final originalUser = User().userId;
        final originalCompany = User().companyId;
        addTearDown(() {
          ctx.cookieId = originalCookie;
          User().userId = originalUser;
          User().companyId = originalCompany;
        });
        final state = await _open(tester, _Store());
        await state.apply(
          state.transaction..insertText(state.getNodeAtPath([0, 0])!, 0, '记录'),
        );
        state.selection = Selection.collapsed(
          Position(path: [0, 0], offset: 2),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('@用户'));
        await tester.pumpAndSettle();
        switch (identity) {
          case 'cookie':
            ctx.cookieId = 'different-session';
          case 'user':
            User().userId = 'different-user';
          case 'company':
            User().companyId = 'different-company';
        }
        await tester.pump(const Duration(milliseconds: 450));
        ctx.cookieId = originalCookie;
        User().userId = originalUser;
        User().companyId = originalCompany;
        await tester.pump();
        expect(
          find.byKey(const ValueKey('mention-user-toolbar-user')),
          findsNothing,
        );
        expect(find.text('当前不可编辑'), findsOneWidget);
        expect(state.editable, isFalse);
        await tester.tap(find.byKey(const ValueKey('mention-close')));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        expect(state.getNodeAtPath([0, 0])!.delta!.toPlainText(), '记录');
        expect(
          find.byKey(const ValueKey('editor-mobile-toolbar')),
          findsNothing,
        );
        await tester.tap(find.byKey(const ValueKey('journal-back')));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'native picker releases its permission watch on cancel and page removal',
    (tester) async {
      final state = await _open(tester, _Store());
      await tester.tap(find.byTooltip('@用户'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mention-close')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(state.getNodeAtPath([0, 0])!.delta!.isEmpty, isTrue);
      expect(state.editable, isTrue);
      expect(state.selection?.start.path, [0, 0]);
      await tester.tap(find.byTooltip('@用户'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('native mention and Todo survive preview and saving', (
    tester,
  ) async {
    final store = _Store();
    final state = await _open(tester, store);
    await state.apply(
      state.transaction..insertText(state.getNodeAtPath([0, 0])!, 0, '记录'),
    );
    state.selection = Selection.collapsed(Position(path: [0, 0], offset: 2));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('@用户'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mention-user-toolbar-user')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('mention-user-toolbar-user')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final node = state.getNodeAtPath([0, 0])!;
    expect(node.delta!.toPlainText(), '记录\uFFFC ');
    expect(
      node.delta!.whereType<TextInsert>().any(
        (op) => op.attributes?['cses_inline_mention'] == '测试同事',
      ),
      isTrue,
    );
    expect(find.text('测试同事'), findsOneWidget);
    await tester.tap(find.byTooltip('撤销'));
    await tester.pumpAndSettle();
    expect(state.getNodeAtPath([0, 0])!.delta!.toPlainText(), '记录');
    expect(state.selection?.start.path, [0, 0]);
    expect(state.selection?.start.offset, 2);
    expect(find.byKey(const ValueKey('editor-mobile-toolbar')), findsOneWidget);
    await tester.tap(find.byTooltip('重做'));
    await tester.pumpAndSettle();
    expect(state.getNodeAtPath([0, 0])!.delta!.toPlainText(), '记录\uFFFC ');
    expect(state.selection?.start.offset, 4);
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.tap(find.byKey(const ValueKey('editor-keyboard-todoList')));
    await tester.pumpAndSettle();
    expect(state.getNodeAtPath([0, 0])!.type, TodoListBlockKeys.type);
    expect(state.getNodeAtPath([0, 0])!.delta!.toPlainText(), '记录\uFFFC ');
    await tester.tap(find.byKey(const ValueKey('journal-preview')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-mobile-toolbar')), findsNothing);
    expect(find.text('测试同事'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('journal-preview')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('journal-back')));
    await tester.pumpAndSettle();
    final restored = JournalDraft.fromJson(store.value.toJson());
    expect(restored.documentJson, contains('cses_inline_mention'));
    expect(restored.documentJson, contains(TodoListBlockKeys.type));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
