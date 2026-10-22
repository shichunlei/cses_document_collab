import 'fixtures.dart';
import 'dart:async';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_ruled_content.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_store.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 日记回归的内存存储，不接触用户草稿或设备文件。
class _Store implements JournalStore {
  /// 最近持久化的不可变快照。
  JournalDraft? value = threeSectionDraft(DateTime(2026, 10, 22));

  /// 返回当前快照。
  @override
  Future<JournalDraft?> read() async => value;

  /// 将独立[draft]作为最近一次保存结果。
  @override
  Future<void> write(JournalDraft draft) async => value = draft;
}

/// 在[tester]中打开借用[store]的页面，以[scale]模拟系统字号；等待加载完成。
Future<void> _open(
  WidgetTester tester,
  _Store store, {
  double scale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: LocalJournalPage(store: store),
    ),
  );
  await tester.pumpAndSettle();
}

/// 从[tester]借用页面实际配置的编辑器，不取得其资源所有权。
AppFlowyEditor _editor(WidgetTester tester) =>
    tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));

/// 卸载[tester]中的日记视图，等待所属会话保存和释放。
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

/// 收集[tester]中今日记录的全部实际横格纵坐标，以检验编辑/预览一致性。
List<double> _lines(WidgetTester tester) =>
    tester
        .renderObjectList<RenderJournalRules>(
          find.descendant(
            of: find.byKey(const ValueKey('journal-section-record')),
            matching: find.byType(JournalRuledContent),
          ),
        )
        .expand((rules) => rules.debugLineOffsets)
        .toList()
      ..sort();

/// 验证原子粘贴、固定栏目删除边界、空列表回车和段尾空行横格。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final shortcut in ['ctrl+v', 'ctrl+shift+v']) {
    for (final text in ['https://example.com', '13800138000', '甲\r\n乙\r丙']) {
      testWidgets(
        '$shortcut pastes plain text atomically, saves and supports undo: $text',
        (tester) async {
          final store = _Store();
          await _open(tester, store);
          final state = _editor(tester).editorState;
          try {
            await state.apply(
              state.transaction
                ..insertText(state.getNodeAtPath([0, 0])!, 0, '前原文后'),
              skipHistoryDebounce: true,
            );
            state.selection = Selection.single(
              path: [0, 0],
              startOffset: 1,
              endOffset: 3,
            );
            // HTML有意包含不允许的块类型；日记应只使用同份剪贴板的纯文本。
            AppFlowyClipboard.mockSetData(
              AppFlowyClipboardData(text: text, html: '<h1>不应进入正文</h1>'),
            );
            final commands = _editor(tester).commandShortcutEvents;
            expect(
              commands.where(
                (event) => event.key.contains('paste the content'),
              ),
              isEmpty,
            );
            expect(
              commands
                  .singleWhere((event) => event.key == 'journal-$shortcut')
                  .handler(state),
              KeyEventResult.handled,
            );
            await tester.pump();
            final expected =
                '前${text.replaceAll('\r\n', '\n').replaceAll('\r', '\n')}后';
            expect(
              state.document.root.children.first.children
                  .map((n) => n.delta!.toPlainText())
                  .join('\n'),
              expected,
            );
            expect(
              state.document.root.children.first.children.every(
                (node) => validJournalDelta(node.delta!),
              ),
              isTrue,
            );
            await tester.pump(const Duration(milliseconds: 600));
            expect(store.value!.documentJson, contains(text.split('\r').first));
            state.undoManager.undo();
            expect(
              state.document.root.children.first.children
                  .map((n) => n.delta!.toPlainText())
                  .join('\n'),
              '前原文后',
            );
            state.undoManager.redo();
            expect(
              state.document.root.children.first.children
                  .map((n) => n.delta!.toPlainText())
                  .join('\n'),
              expected,
            );
            await _unmount(tester);
            await _open(tester, store);
            expect(
              _editor(tester).editorState.document.root.children.first.children
                  .map((n) => n.delta!.toPlainText())
                  .join('\n'),
              expected,
            );
          } finally {
            AppFlowyClipboard.mockSetData(null);
            await _unmount(tester);
          }
        },
      );
    }
  }

  test(
    'paste port rejects overflow, objects and cross-section replacement without changing content or history',
    () async {
      final store = _Store();
      final journal = await openTestJournal(store: store);
      final state = journal.editor.editorState;
      try {
        await state.apply(
          state.transaction..insertText(state.getNodeAtPath([0, 0])!, 0, '原文'),
        );
        // 预先填入其他栏目，验证最终整篇容量校验，而非仅检查剪贴板自身长度。
        await state.apply(
          state.transaction
            ..insertText(state.getNodeAtPath([1, 0])!, 0, '占用容量'),
        );
        state.selection = Selection.single(
          path: [0, 0],
          startOffset: 0,
          endOffset: 2,
        );
        final before = jsonEncode(state.document.toJson());
        final selection = state.selection;
        final history = state.undoManager.undoStack.last;
        final paste = EditorCommandContext.of(state).pastePlainText!;
        for (final text in [
          'x' * journalConfiguration.maxCharacters,
          '\uFFFC',
          List.filled(journalConfiguration.maxBlocks, 'a').join('\n'),
        ]) {
          AppFlowyClipboard.mockSetData(AppFlowyClipboardData(text: text));
          await expectLater(paste(), throwsStateError);
          expect(jsonEncode(state.document.toJson()), before);
          expect(state.selection, selection);
          expect(state.undoManager.undoStack.last, history);
        }
        state.selection = Selection(
          start: Position(path: [0, 0]),
          end: Position(path: [1, 0], offset: 1),
        );
        AppFlowyClipboard.mockSetData(
          const AppFlowyClipboardData(text: 'https://example.com'),
        );
        await paste();
        expect(jsonEncode(state.document.toJson()), before);
        expect(await journal.flush(), isTrue);
        expect(store.value!.documentJson, before);
      } finally {
        AppFlowyClipboard.mockSetData(null);
        await journal.close();
      }
    },
  );

  test(
    'multi-paragraph paste retains outer formatting and restores the whole range with one undo',
    () async {
      final journal = await openTestJournal(store: _Store());
      final state = journal.editor.editorState;
      try {
        final prefix = Delta()
          ..insert('前', attributes: {AppFlowyRichTextKeys.bold: true})
          ..insert('待替换');
        final suffix = Delta()
          ..insert('待替换')
          ..insert('后', attributes: {AppFlowyRichTextKeys.italic: true});
        await state.apply(
          state.transaction
            ..updateNode(state.getNodeAtPath([1, 0])!, {
              blockComponentDelta: prefix.toJson(),
            })
            ..insertNode([1, 1], paragraphNode(delta: suffix)),
          skipHistoryDebounce: true,
        );
        final before = jsonEncode(state.document.toJson());
        state.selection = Selection(
          start: Position(path: [1, 1], offset: 3),
          end: Position(path: [1, 0], offset: 1),
        );
        AppFlowyClipboard.mockSetData(
          const AppFlowyClipboardData(text: 'https://example.com\n中'),
        );
        await journal.pasteFromClipboard();
        expect(
          state.getNodeAtPath([1, 0])!.delta!.toPlainText(),
          '前https://example.com',
        );
        expect(state.getNodeAtPath([1, 1])!.delta!.toPlainText(), '中后');
        expect(
          state.getNodeAtPath([1, 0])!.delta!.slice(0, 1).first.attributes,
          {AppFlowyRichTextKeys.bold: true},
        );
        expect(
          state.getNodeAtPath([1, 1])!.delta!.slice(1, 2).first.attributes,
          {AppFlowyRichTextKeys.italic: true},
        );
        final after = jsonEncode(state.document.toJson());
        state.undoManager.undo();
        expect(jsonEncode(state.document.toJson()), before);
        state.undoManager.redo();
        expect(jsonEncode(state.document.toJson()), after);
      } finally {
        AppFlowyClipboard.mockSetData(null);
        await journal.close();
      }
    },
  );

  testWidgets(
    'rejected shortcut paste shows a retry message and keeps the saved original',
    (tester) async {
      final store = _Store();
      await _open(tester, store);
      final state = _editor(tester).editorState;
      try {
        await state.apply(
          state.transaction..insertText(state.getNodeAtPath([0, 0])!, 0, '原文'),
        );
        state.selection = Selection.single(
          path: [0, 0],
          startOffset: 0,
          endOffset: 2,
        );
        AppFlowyClipboard.mockSetData(
          const AppFlowyClipboardData(text: '\uFFFC'),
        );
        _editor(tester).commandShortcutEvents
            .singleWhere((event) => event.key == 'journal-ctrl+v')
            .handler(state);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(state.getNodeAtPath([0, 0])!.delta!.toPlainText(), '原文');
        expect(store.value!.documentJson, contains('原文'));
        expect(find.text('粘贴失败，原文已保留，请检查内容或重试'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        AppFlowyClipboard.mockSetData(null);
        await _unmount(tester);
      }
    },
  );

  test(
    'fixed-section guard allows inline formatting across sections',
    () async {
      final journal = await openTestJournal(store: _Store());
      final state = journal.editor.editorState;
      try {
        for (var section = 0; section < 3; section++) {
          await state.apply(
            state.transaction
              ..insertText(state.getNodeAtPath([section, 0])!, 0, '正文'),
          );
        }
        final transaction = state.transaction;
        for (var section = 0; section < 3; section++) {
          transaction.formatText(state.getNodeAtPath([section, 0])!, 0, 2, {
            AppFlowyRichTextKeys.bold: true,
          });
        }
        expect(state.canApplyTransaction(transaction), isTrue);
        await state.apply(transaction);
        expect(
          state.document.root.children.every(
            (section) =>
                section
                    .children
                    .single
                    .delta!
                    .first
                    .attributes?[AppFlowyRichTextKeys.bold] ==
                true,
          ),
          isTrue,
        );
      } finally {
        await journal.close();
      }
    },
  );

  for (final change in ['edit', 'selection', 'close']) {
    test('pending clipboard read cannot overwrite after $change', () async {
      final journal = await openTestJournal(store: _Store());
      final state = journal.editor.editorState;
      final gate = Completer<Object?>();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData' ? gate.future : null,
      );
      try {
        await state.apply(
          state.transaction..insertText(state.getNodeAtPath([0, 0])!, 0, '原文'),
        );
        state.selection = Selection.single(
          path: [0, 0],
          startOffset: 0,
          endOffset: 2,
        );
        final paste = journal.pasteFromClipboard();
        final result = change == 'close'
            ? expectLater(paste, completes)
            : expectLater(paste, throwsStateError);
        if (change == 'edit') {
          await state.apply(
            state.transaction
              ..insertText(state.getNodeAtPath([0, 0])!, 2, '新内容'),
          );
        } else if (change == 'selection') {
          state.selection = Selection.collapsed(Position(path: [1, 0]));
        } else {
          await journal.close();
        }
        gate.complete({'text': '迟到的链接https://example.com'});
        await result;
        if (change != 'close') {
          expect(
            state.getNodeAtPath([0, 0])!.delta!.toPlainText(),
            change == 'edit' ? '原文新内容' : '原文',
          );
        }
      } finally {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        await journal.close();
      }
    });
  }

  for (final input in ['backspace', 'delete', 'ime']) {
    testWidgets(
      '$input preserves fixed section boundaries and allows same-section merge',
      (tester) async {
        await _open(tester, _Store());
        final state = _editor(tester).editorState;
        try {
          for (var section = 0; section < 3; section++) {
            await state.apply(
              state.transaction
                ..insertText(
                  state.getNodeAtPath([section, 0])!,
                  0,
                  '首行$section',
                )
                ..insertNode([section, 1], paragraphNode(text: '次行$section')),
            );
          }
          final before = jsonEncode(state.document.toJson());
          for (final section in [1, 2]) {
            state.selection = Selection.collapsed(
              Position(
                path: input == 'delete' ? [section - 1, 1] : [section, 0],
                offset: input == 'delete' ? 3 : 0,
              ),
            );
            await tester.pump();
            if (input == 'ime') {
              final keyboard = tester.state<KeyboardServiceWidgetState>(
                find.byType(KeyboardServiceWidget),
              );
              await keyboard.textInputService.apply([
                const TextEditingDeltaDeletion(
                  oldText: '',
                  deletedRange: TextRange.collapsed(0),
                  selection: TextSelection.collapsed(offset: 0),
                  composing: TextRange.empty,
                ),
              ]);
            } else {
              (input == 'delete' ? deleteCommand : backspaceCommand).handler(
                state,
              );
              await tester.pump();
            }
            expect(jsonEncode(state.document.toJson()), before);
          }
          state.selection = Selection.collapsed(Position(path: [2, 1]));
          backspaceCommand.handler(state);
          await tester.pump();
          expect(
            state.document.root.children.last.children.single.delta!
                .toPlainText(),
            '首行2次行2',
          );
        } finally {
          await _unmount(tester);
        }
      },
    );
  }

  for (final type in [
    TodoListBlockKeys.type,
    BulletedListBlockKeys.type,
    NumberedListBlockKeys.type,
  ]) {
    testWidgets(
      'empty $type Enter returns to paragraph and supports undo/redo',
      (tester) async {
        await _open(tester, _Store());
        final state = _editor(tester).editorState;
        try {
          final original = state.getNodeAtPath([1, 0])!;
          await state.apply(
            state.transaction
              ..insertNode(
                original.path,
                Node(
                  type: type,
                  attributes: {
                    blockComponentDelta: Delta().toJson(),
                    if (type == TodoListBlockKeys.type)
                      TodoListBlockKeys.checked: true,
                  },
                ),
              )
              ..deleteNode(original),
            skipHistoryDebounce: true,
          );
          state.selection = Selection.collapsed(Position(path: [1, 0]));
          await tester.pump();
          final keyboard = tester.state<KeyboardServiceWidgetState>(
            find.byType(KeyboardServiceWidget),
          );
          await keyboard.textInputService.apply([
            const TextEditingDeltaInsertion(
              oldText: '',
              textInserted: '\n',
              insertionOffset: 0,
              selection: TextSelection.collapsed(offset: 1),
              composing: TextRange.empty,
            ),
          ]);
          expect(state.getNodeAtPath([1, 0])!.type, ParagraphBlockKeys.type);
          expect(state.getNodeAtPath([1, 0])!.delta!.toPlainText(), isEmpty);
          expect(state.selection, Selection.collapsed(Position(path: [1, 0])));
          state.undoManager.undo();
          expect(state.getNodeAtPath([1, 0])!.type, type);
          if (type == TodoListBlockKeys.type) {
            expect(
              state.getNodeAtPath([
                1,
                0,
              ])!.attributes[TodoListBlockKeys.checked],
              isTrue,
            );
          }
          state.undoManager.redo();
          expect(state.getNodeAtPath([1, 0])!.type, ParagraphBlockKeys.type);
          expect(
            state.document.root.children.map(
              (node) => node.attributes['section'],
            ),
            journalSections,
          );
        } finally {
          await _unmount(tester);
        }
      },
    );
  }

  for (final scale in [1.0, 2.0]) {
    for (final text in ['第一行\n', '第一行\n\n\n', '\n\n', '首行\n\n末行']) {
      testWidgets(
        'all soft lines remain ruled in edit and preview: ${jsonEncode(text)} / $scale',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(390, 1400));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await _open(tester, _Store(), scale: scale);
          final state = _editor(tester).editorState;
          try {
            await state.apply(
              state.transaction
                ..insertText(state.getNodeAtPath([0, 0])!, 0, text),
            );
            await tester.pumpAndSettle();
            final count = text.split('\n').length < 3
                ? 3
                : text.split('\n').length;
            final expected = List.generate(
              count,
              (index) => (index + 1) * 32 * scale,
            );
            expect(_lines(tester), expected);
            await tester.tap(find.byKey(const ValueKey('journal-preview')));
            await tester.pumpAndSettle();
            expect(_editor(tester).editorState.editable, isFalse);
            expect(_lines(tester), expected);
          } finally {
            await _unmount(tester);
          }
        },
      );
    }
  }
}
