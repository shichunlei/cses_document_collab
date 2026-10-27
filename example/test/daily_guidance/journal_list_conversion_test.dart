import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_store.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用独立草稿快照支持真实页面加载和自动保存，不访问用户文件或网络。
final class _Store implements JournalStore {
  /// [value]为已校验的列表草稿；调用方不保留可变编辑器文档。
  _Store(this.value);

  /// 最近成功保存的不可变快照。
  JournalDraft value;

  /// 返回JSON往返副本，模拟本地文件重新打开。
  @override
  Future<JournalDraft?> read() async => JournalDraft.fromJson(value.toJson());

  /// 校验并保存[draft]的JSON往返副本。
  @override
  Future<void> write(JournalDraft draft) async =>
      value = JournalDraft.fromJson(draft.toJson());
}

/// 用[source]构建日记真实栏目层级内的源列表，保留富文本和已勾选Todo语义。
JournalDraft _draft(String source) {
  final blank = JournalDraft.blank(DateTime(2026, 10, 22));
  final document = Document(
    root: Node(
      type: PageBlockKeys.type,
      children: [
        Node(
          type: journalSectionType,
          attributes: {'section': 'record'},
          children: [
            Node(
              type: source,
              attributes: {
                blockComponentDelta:
                    (Delta()
                          ..insert('甲乙', attributes: {'bold': true})
                          ..insert('丙丁', attributes: {'italic': true}))
                        .toJson(),
                if (source == TodoListBlockKeys.type)
                  TodoListBlockKeys.checked: true,
              },
            ),
            paragraphNode(text: '相邻记录保持原样'),
          ],
        ),
      ],
    ),
  );
  try {
    return JournalDraft.fromJson({
      ...blank.toJson(),
      'document': document.toJson(),
    });
  } finally {
    document.dispose();
  }
}

/// 在[tester]中打开[source]的持久化日记并定位列表光标，返回借用的页面编辑会话。
Future<EditorState> _open(WidgetTester tester, String source) async {
  await tester.binding.setSurfaceSize(const Size(390, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  tester.view.devicePixelRatio = 1;
  tester.view.viewInsets = const FakeViewPadding(bottom: 260);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(
    MaterialApp(home: LocalJournalPage(store: _Store(_draft(source)))),
  );
  await tester.pumpAndSettle();
  final state = tester
      .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
      .editorState;
  state.selection = Selection.collapsed(Position(path: [0, 0], offset: 2));
  await tester.pumpAndSettle();
  return state;
}

/// 在[tester]中展开真实T菜单，横向滚动后点击[target]类型；已展开时保留同一菜单会话。
Future<void> _chooseType(WidgetTester tester, String target) async {
  if (find
      .byKey(const ValueKey('editor-block-style-menu'))
      .evaluate()
      .isEmpty) {
    await tester.tap(find.byTooltip('块类型'));
    await tester.pumpAndSettle();
  }
  final action = find.byKey(ValueKey('editor-block-$target-0'));
  for (var i = 0; i < 10 && action.hitTestable().evaluate().isEmpty; i++) {
    await tester.drag(
      find.byKey(const ValueKey('editor-block-style-menu')),
      const Offset(-130, 0),
    );
    await tester.pumpAndSettle();
  }
  expect(action.hitTestable(), findsOneWidget);
  await tester.tap(action);
  await tester.pumpAndSettle();
}

/// 验证真实日记T菜单在三种列表间直接互换，包含正文、格式、光标及独立历史。
void main() {
  const types = [
    BulletedListBlockKeys.type,
    NumberedListBlockKeys.type,
    TodoListBlockKeys.type,
  ];
  for (final source in types) {
    for (final target in types.where((type) => type != source)) {
      testWidgets(
        'T menu directly converts $source to $target in journal section',
        (tester) async {
          final state = await _open(tester, source);
          try {
            final before = state.getNodeAtPath([0, 0])!.delta!.toJson();
            final neighbor = state.getNodeAtPath([0, 1])!.toJson();
            final selection = state.selection;
            expect(state.undoManager.undoStack.isEmpty, isTrue);
            await _chooseType(tester, target);
            final converted = state.getNodeAtPath([0, 0])!;
            expect(converted.type, target);
            expect(converted.delta!.toJson(), before);
            expect(state.getNodeAtPath([0, 1])!.toJson(), neighbor);
            expect(state.selection, selection);
            expect(
              converted.attributes[TodoListBlockKeys.checked],
              target == TodoListBlockKeys.type ? false : isNull,
            );
            expect(state.undoManager.undoStack.isNonEmpty, isTrue);
            validateJournalDocument(state.document);
            await tester.tap(find.byTooltip('撤销'));
            await tester.pumpAndSettle();
            final undone = state.getNodeAtPath([0, 0])!;
            expect(state.undoManager.undoStack.isEmpty, isTrue);
            expect(undone.type, source);
            expect(undone.delta!.toJson(), before);
            expect(state.selection, selection);
            expect(
              undone.attributes[TodoListBlockKeys.checked],
              source == TodoListBlockKeys.type ? true : isNull,
            );
            await tester.tap(find.byTooltip('重做'));
            await tester.pumpAndSettle();
            expect(state.getNodeAtPath([0, 0])!.type, target);
            expect(state.getNodeAtPath([0, 0])!.delta!.toJson(), before);
            expect(state.selection, selection);
            expect(state.getNodeAtPath([0, 1])!.toJson(), neighbor);
            expect(tester.testTextInput.isVisible, isTrue);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          }
        },
      );
    }
  }

  for (final source in types.take(2)) {
    testWidgets(
      'direct Todo shortcut converts $source inside journal section',
      (tester) async {
        final state = await _open(tester, source);
        try {
          final before = state.getNodeAtPath([0, 0])!.delta!.toJson();
          final selection = state.selection;
          await tester.tap(
            find.byKey(const ValueKey('editor-keyboard-todoList')),
          );
          await tester.pumpAndSettle();
          final node = state.getNodeAtPath([0, 0])!;
          expect(node.type, TodoListBlockKeys.type);
          expect(node.attributes[TodoListBlockKeys.checked], isFalse);
          expect(node.delta!.toJson(), before);
          expect(state.selection, selection);
          await tester.tap(find.byTooltip('撤销'));
          await tester.pumpAndSettle();
          expect(state.getNodeAtPath([0, 0])!.type, source);
          expect(state.undoManager.undoStack.isEmpty, isTrue);
          expect(state.selection, selection);
          await tester.tap(find.byTooltip('重做'));
          await tester.pumpAndSettle();
          expect(state.getNodeAtPath([0, 0])!.type, TodoListBlockKeys.type);
          expect(state.getNodeAtPath([0, 0])!.delta!.toJson(), before);
          expect(state.selection, selection);
          expect(tester.testTextInput.isVisible, isTrue);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
      },
    );
  }

  testWidgets('same Todo shortcut keeps checked state without extra history', (
    tester,
  ) async {
    final state = await _open(tester, TodoListBlockKeys.type);
    try {
      final before = state.getNodeAtPath([0, 0])!.delta!.toJson();
      final selection = state.selection;
      await tester.tap(find.byKey(const ValueKey('editor-keyboard-todoList')));
      await tester.pumpAndSettle();
      final node = state.getNodeAtPath([0, 0])!;
      expect(node.type, TodoListBlockKeys.type);
      expect(node.attributes[TodoListBlockKeys.checked], isTrue);
      expect(node.delta!.toJson(), before);
      expect(state.selection, selection);
      expect(state.undoManager.undoStack.isEmpty, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });

  testWidgets('consecutive T list conversions keep independent undo and redo', (
    tester,
  ) async {
    final state = await _open(tester, BulletedListBlockKeys.type);
    try {
      final before = state.getNodeAtPath([0, 0])!.delta!.toJson();
      final neighbor = state.getNodeAtPath([0, 1])!.toJson();
      final selection = state.selection;
      const sequence = [
        BulletedListBlockKeys.type,
        NumberedListBlockKeys.type,
        TodoListBlockKeys.type,
        BulletedListBlockKeys.type,
      ];
      for (final target in sequence.skip(1)) {
        await _chooseType(tester, target);
        final node = state.getNodeAtPath([0, 0])!;
        expect(node.type, target);
        expect(node.delta!.toJson(), before);
        expect(state.selection, selection);
        expect(
          node.attributes[TodoListBlockKeys.checked],
          target == TodoListBlockKeys.type ? false : isNull,
        );
      }
      for (final target in sequence.take(3).toList().reversed) {
        await tester.tap(find.byTooltip('撤销'));
        await tester.pumpAndSettle();
        expect(state.getNodeAtPath([0, 0])!.type, target);
        expect(state.getNodeAtPath([0, 0])!.delta!.toJson(), before);
        expect(state.selection, selection);
      }
      expect(state.undoManager.undoStack.isEmpty, isTrue);
      for (final target in sequence.skip(1)) {
        await tester.tap(find.byTooltip('重做'));
        await tester.pumpAndSettle();
        expect(state.getNodeAtPath([0, 0])!.type, target);
        expect(state.getNodeAtPath([0, 0])!.delta!.toJson(), before);
        expect(state.selection, selection);
      }
      expect(state.getNodeAtPath([0, 1])!.toJson(), neighbor);
      validateJournalDocument(state.document);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });
}
