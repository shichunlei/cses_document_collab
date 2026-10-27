import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 验证宿主快捷动作的顺序、互斥、错误和会话失效，以及原生待办事务。
void main() {
  for (final menu in ['块类型', '文字样式', '对齐与缩进']) {
    testWidgets('review regression: pending host action synchronously blocks $menu', (tester) async {
      final pending = Completer<void>();
      final local = LocalEditorController(
        initialText: '正文',
        configuration: EditorConfiguration(
          keyboardToolbarItems: [
            EditorKeyboardToolbarItem.blockType,
            EditorKeyboardToolbarItem.textStyle,
            EditorKeyboardToolbarItem.blockLayout,
          ],
        ),
      );
      final scroll = await _mount(tester, local, [_action('host', '宿主', () => pending.future)]);
      try {
        await tester.tap(find.text('宿主'));
        await tester.tap(find.byTooltip(menu));
        await tester.pumpAndSettle();
        expect(pending.isCompleted, isFalse);
        expect(find.byKey(const ValueKey('editor-toolbar-popup')), findsNothing);
        expect(local.editorState.document.first!.type, ParagraphBlockKeys.type);
        pending.complete();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip(menu));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('editor-toolbar-popup')), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        if (!pending.isCompleted) pending.complete();
        await _close(tester, [local], [scroll]);
      }
    });
  }

  testWidgets('review regression: pending host action invalidates an existing submenu callback', (tester) async {
    final pending = Completer<void>();
    final local = LocalEditorController(
      initialText: '正文',
      configuration: EditorConfiguration(keyboardToolbarItems: [EditorKeyboardToolbarItem.blockType]),
    );
    final scroll = await _mount(tester, local, [_action('host', '宿主', () => pending.future)]);
    try {
      await tester.tap(find.byTooltip('块类型'));
      await tester.pumpAndSettle();
      final target = find.byKey(const ValueKey('editor-block-todo_list-0'));
      final press = tester.widget<InkWell>(find.descendant(of: target, matching: find.byType(InkWell))).onTap!;
      await tester.tap(find.text('宿主'));
      press();
      await tester.pumpAndSettle();
      expect(pending.isCompleted, isFalse);
      expect(local.editorState.document.first!.type, ParagraphBlockKeys.type);
      expect(find.byKey(const ValueKey('editor-toolbar-popup')), findsNothing);
      pending.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    } finally {
      if (!pending.isCompleted) pending.complete();
      await _close(tester, [local], [scroll]);
    }
  });

  testWidgets('host labels follow built-ins and disabled actions cannot execute', (tester) async {
    final local = LocalEditorController(
      initialText: '正文',
      configuration: EditorConfiguration(keyboardToolbarItems: [EditorKeyboardToolbarItem.blockType]),
    );
    var calls = 0;
    final scroll = await _mount(tester, local, [
      _action('reflection', '感悟', () async => calls++),
      _action('self-check', '自检', () async => calls++, enabled: false),
    ]);
    try {
      expect(tester.getCenter(find.byTooltip('块类型')).dx, lessThan(tester.getCenter(find.text('感悟')).dx));
      expect(tester.getCenter(find.text('感悟')).dx, lessThan(tester.getCenter(find.text('自检')).dx));
      expect(_button(tester, 'self-check').onPressed, isNull);
      await tester.tap(find.text('自检'));
      await tester.pump();
      expect(calls, 0);
      await tester.tap(find.text('感悟'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      final stalePress = _button(tester, 'reflection').onPressed!;
      local.editorState.editable = false;
      stalePress();
      await tester.pump();
      expect(calls, 1);
      expect(find.byKey(const ValueKey('editor-mobile-toolbar')), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await _close(tester, [local], [scroll]);
    }
  });

  testWidgets('pending host action rejects repeat taps and disables other shortcuts', (tester) async {
    final pending = Completer<void>();
    var first = 0;
    var second = 0;
    final local = LocalEditorController(
      initialText: '正文',
      configuration: EditorConfiguration(keyboardToolbarItems: [EditorKeyboardToolbarItem.todoList]),
    );
    final scroll = await _mount(tester, local, [
      _action('reflection', '感悟', () {
        first++;
        return pending.future;
      }),
      _action('pilot', '领航员', () async => second++),
    ]);
    try {
      final press = _button(tester, 'reflection').onPressed!;
      press();
      press();
      await tester.pump();
      expect(first, 1);
      expect(_button(tester, 'reflection').onPressed, isNull);
      expect(_button(tester, 'pilot').onPressed, isNull);
      expect(
        tester
            .widget<IconButton>(find.ancestor(of: find.byTooltip('待办列表'), matching: find.byType(IconButton)))
            .onPressed,
        isNull,
      );
      expect(second, 0);
      pending.complete();
      await tester.pumpAndSettle();
      expect(_button(tester, 'reflection').onPressed, isNotNull);
      expect(_button(tester, 'pilot').onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    } finally {
      if (!pending.isCompleted) pending.complete();
      await _close(tester, [local], [scroll]);
    }
  });

  testWidgets('current host failure is reported and the action becomes available again', (tester) async {
    final failure = StateError('host rejected transaction');
    final errors = <Object>[];
    final local = LocalEditorController(
      initialText: '正文',
      configuration: EditorConfiguration(keyboardToolbarItems: const []),
      services: CollabHostServices(onError: (_, error, _, _) => errors.add(error)),
    );
    final scroll = await _mount(tester, local, [_action('reflection', '感悟', () => Future<void>.error(failure))]);
    try {
      await tester.tap(find.text('感悟'));
      await tester.pumpAndSettle();
      expect(errors, [failure]);
      expect(find.text('感悟失败，请重试'), findsOneWidget);
      expect(_button(tester, 'reflection').onPressed, isNotNull);
      expect(local.editorState.document.root.children.single.delta!.toPlainText(), '正文');
      expect(tester.takeException(), isNull);
    } finally {
      await _close(tester, [local], [scroll]);
    }
  });

  testWidgets('old editor completion cannot report into or unlock a new pending action', (tester) async {
    final oldPending = Completer<void>();
    final newPending = Completer<void>();
    final errors = <Object>[];
    final old = LocalEditorController(
      initialText: '旧正文',
      configuration: EditorConfiguration(keyboardToolbarItems: const []),
      services: CollabHostServices(onError: (_, error, _, _) => errors.add(error)),
    );
    final next = LocalEditorController(
      initialText: '新正文',
      configuration: EditorConfiguration(keyboardToolbarItems: const []),
    );
    final oldScroll = await _mount(tester, old, [_action('reflection', '感悟', () => oldPending.future)]);
    await tester.tap(find.text('感悟'));
    await tester.pump();
    final newScroll = await _mount(tester, next, [_action('reflection', '感悟', () => newPending.future)]);
    try {
      await tester.tap(find.text('感悟'));
      await tester.pump();
      oldPending.completeError(StateError('late failure'));
      await tester.pumpAndSettle();
      expect(errors, isEmpty);
      expect(find.text('感悟失败，请重试'), findsNothing);
      expect(_button(tester, 'reflection').onPressed, isNull);
      newPending.complete();
      await tester.pumpAndSettle();
      expect(_button(tester, 'reflection').onPressed, isNotNull);
      expect(next.editorState.document.root.children.single.delta!.toPlainText(), '新正文');
      expect(tester.takeException(), isNull);
    } finally {
      if (!oldPending.isCompleted) oldPending.complete();
      if (!newPending.isCompleted) newPending.complete();
      await _close(tester, [old, next], [oldScroll, newScroll]);
    }
  });

  testWidgets('todo shortcut converts current text and preserves checked state on repeated selection', (tester) async {
    final local = LocalEditorController(
      initialText: '保留正文',
      configuration: EditorConfiguration(keyboardToolbarItems: [EditorKeyboardToolbarItem.todoList]),
    );
    final scroll = await _mount(tester, local, const []);
    final state = local.editorState;
    try {
      final node = state.document.root.children.single;
      final delta = Delta()..insert('保留正文', attributes: {AppFlowyRichTextKeys.bold: true});
      await state.apply(state.transaction..updateNode(node, {blockComponentDelta: delta.toJson()}));
      state.undoManager.undoStack.clear();
      final selection = Selection.single(path: [0], startOffset: 2);
      state.selection = selection;
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-keyboard-todoList')));
      await tester.pumpAndSettle();
      final todo = state.document.root.children.single;
      expect(todo.type, TodoListBlockKeys.type);
      expect(todo.delta, delta);
      expect(todo.attributes[TodoListBlockKeys.checked], isFalse);
      expect(state.selection, selection);
      await state.apply(
        state.transaction..updateNode(todo, {TodoListBlockKeys.checked: true}),
        skipHistoryDebounce: true,
      );
      final historyItem = state.undoManager.undoStack.last;
      await tester.tap(find.byKey(const ValueKey('editor-keyboard-todoList')));
      await tester.pumpAndSettle();
      expect(state.document.root.children.single.attributes[TodoListBlockKeys.checked], isTrue);
      expect(state.undoManager.undoStack.last, same(historyItem));
      state.undoManager.undo();
      await tester.pumpAndSettle();
      state.undoManager.undo();
      await tester.pumpAndSettle();
      expect(state.document.root.children.single.type, ParagraphBlockKeys.type);
      expect(state.document.root.children.single.delta, delta);
      expect(state.selection, selection);
      expect(tester.takeException(), isNull);
    } finally {
      await _close(tester, [local], [scroll]);
    }
  });
}

/// 用[id]/[label]创建测试动作；[run]拥有异步完成，[enabled]默认true。
EditorKeyboardAction _action(String id, String label, Future<void> Function() run, {bool enabled = true}) =>
    EditorKeyboardAction(id: id, label: label, icon: LucideIcons.lightbulb, enabled: enabled, onPressed: run);

/// 从[tester]当前树中取得[id]对应的外层按钮，检查真实禁用语义。
IconButton _button(WidgetTester tester, String id) => tester.widget<IconButton>(
  find.ancestor(of: find.byKey(ValueKey('editor-keyboard-host-$id')), matching: find.byType(IconButton)),
);

/// 为[local]借用[actions]挂载公共交互壳；[tester]拥有测试边距，返回由调用方释放的滚动器。
Future<EditorScrollController> _mount(
  WidgetTester tester,
  LocalEditorController local,
  List<EditorKeyboardAction> actions,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.viewInsets = const FakeViewPadding(bottom: 260);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  final scroll = EditorScrollController(editorState: local.editorState);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        AppFlowyEditorLocalizations.delegate,
      ],
      home: Scaffold(
        body: EditorInteractionShell(
          editorState: local.editorState,
          scrollController: scroll,
          keyboardActions: actions,
          child: AppFlowyEditor(editorState: local.editorState, editorScrollController: scroll),
        ),
      ),
    ),
  );
  local.editorState.selection = Selection.single(path: [0], startOffset: 0);
  await tester.pumpAndSettle();
  return scroll;
}

/// 用[tester]卸载视图，再释放本测试拥有的[scrolls]和[editors]，不遗留输入连接。
Future<void> _close(
  WidgetTester tester,
  List<LocalEditorController> editors,
  List<EditorScrollController> scrolls,
) async {
  for (final editor in editors) {
    editor.editorState.selection = null;
  }
  await tester.pumpWidget(const SizedBox.shrink());
  tester.testTextInput.unregister();
  await tester.pump(const Duration(milliseconds: 500));
  for (final scroll in scrolls) {
    scroll.dispose();
  }
  for (final editor in editors) {
    await tester.runAsync(editor.close);
  }
}
