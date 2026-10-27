import 'dart:async';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/guidance_entries.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/guidance_people.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_store.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 剪贴板回归使用的独立快照存储，不读写用户文件。
class _Store implements JournalStore {
  /// 最近保存的不可变草稿。
  JournalDraft? value;

  /// 返回当前保存内容。
  @override
  Future<JournalDraft?> read() async => value;

  /// 将[draft]编码往返，避免保存数据与正在编辑的节点共享对象。
  @override
  Future<void> write(JournalDraft draft) async =>
      value = JournalDraft.fromJson(draft.toJson());
}

/// 在借用[store]中创建测试会话，使用长去抖以控制保存时机；调用方负责close。
Future<LocalJournalController> _open(_Store store) =>
    LocalJournalController.open(
      store: store,
      now: DateTime(2026, 10, 22),
      saveDelay: const Duration(days: 1),
    );

/// 在[journal]今日记录插入人员与说明，返回同一会话拥有的叶子。
Future<Node> _mention(LocalJournalController journal) async {
  final state = journal.editor.editorState;
  final node = state.getNodeAtPath([0, 0])!;
  state.selection = Selection.collapsed(Position(path: node.path));
  await journal.insertPeople(journal.captureInsertionTarget()!, const [
    GuidancePerson(id: 'u1', name: '张三'),
  ]);
  await state.apply(
    state.transaction..insertText(node, node.delta!.length, '说明😀'),
  );
  return node;
}

/// 返回[node]全部文字的正向选区，并写入[journal]当前光标。
Selection _select(LocalJournalController journal, Node node) {
  final selection = Selection.single(
    path: node.path,
    startOffset: 0,
    endOffset: node.delta!.length,
  );
  journal.editor.editorState.selection = selection;
  return selection;
}

/// 验证安全可读剪贴板、写失败与迟到结果不会删除源正文。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    AppFlowyClipboard.mockSetData(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test(
    'mention copy yields readable names, ordinary Unicode and no model mutation',
    () async {
      final journal = await _open(_Store());
      try {
        final node = await _mention(journal);
        final before = jsonEncode(journal.editor.editorState.document.toJson());
        final history = journal.editor.editorState.undoManager.undoStack.last;
        await journal.copySelection(_select(journal, node));
        expect(AppFlowyClipboard.lastText, '@张三 说明😀');
        expect(AppFlowyClipboard.lastText, isNot(contains('\uFFFC')));
        expect(
          jsonEncode(journal.editor.editorState.document.toJson()),
          before,
        );
        expect(
          journal.editor.editorState.undoManager.undoStack.last,
          same(history),
        );
      } finally {
        await journal.close();
      }
    },
  );

  test(
    'cut saved and reopened draft can paste readable names and undo/redo the move',
    () async {
      final store = _Store();
      final journal = await _open(store);
      String? copied;
      try {
        final node = await _mention(journal);
        final original = node.delta!.toJson();
        final state = journal.editor.editorState;
        await journal.copySelection(_select(journal, node), cut: true);
        copied = AppFlowyClipboard.lastText;
        expect(node.delta!.toPlainText(), isEmpty);
        expect(copied, '@张三 说明😀');
        state.undoManager.undo();
        expect(node.delta!.toJson(), original);
        state.undoManager.redo();
        expect(node.delta!.toPlainText(), isEmpty);
        expect(await journal.flush(), isTrue);
      } finally {
        await journal.close();
      }
      final reopened = await _open(store);
      try {
        final node = reopened.editor.editorState.getNodeAtPath([0, 0])!;
        reopened.editor.editorState.selection = Selection.collapsed(
          Position(path: node.path),
        );
        AppFlowyClipboard.mockSetData(AppFlowyClipboardData(text: copied));
        await reopened.pasteFromClipboard();
        expect(node.delta!.toPlainText(), '@张三 说明😀');
        expect(
          node.delta!.every(
            (op) => op.attributes?[guidanceMentionAttribute] == null,
          ),
          isTrue,
        );
        expect(await reopened.flush(), isTrue);
      } finally {
        await reopened.close();
      }
    },
  );

  test(
    'selected department and user objects expand independently of display width',
    () async {
      final journal = await _open(_Store());
      try {
        final state = journal.editor.editorState;
        final node = state.getNodeAtPath([0, 0])!;
        state.selection = Selection.collapsed(Position(path: node.path));
        await journal.insertPeople(journal.captureInsertionTarget()!, const [
          GuidancePerson(id: 'same', name: '张三'),
          GuidancePerson(id: 'same', name: '研发部', type: 'department'),
        ]);
        await journal.copySelection(
          Selection.single(path: node.path, startOffset: 2, endOffset: 3),
        );
        expect(AppFlowyClipboard.lastText, '@研发部');
        expect(node.delta!.toPlainText(), '\uFFFC \uFFFC ');
      } finally {
        await journal.close();
      }
    },
  );

  test(
    'multiline cut keeps readable references and supports one undo',
    () async {
      final journal = await _open(_Store());
      try {
        final state = journal.editor.editorState;
        final node = await _mention(journal);
        await state.apply(
          state.transaction..insertNode([0, 1], paragraphNode(text: '第二段')),
        );
        final before = state.document.root.children.single.children
            .map((node) => {'type': node.type, 'delta': node.delta!.toJson()})
            .toList();
        final selection = Selection(
          start: Position(path: [0, 0]),
          end: Position(path: [0, 1], offset: 3),
        );
        state.selection = selection;
        await journal.copySelection(selection, cut: true);
        expect(AppFlowyClipboard.lastText, '@张三 说明😀\n第二段');
        expect(node.delta!.toPlainText(), isEmpty);
        state.undoManager.undo();
        expect(
          state.document.root.children.single.children
              .map((node) => {'type': node.type, 'delta': node.delta!.toJson()})
              .toList(),
          before,
        );
      } finally {
        await journal.close();
      }
    },
  );

  test(
    'failed platform clipboard write preserves content and undo history',
    () async {
      final journal = await _open(_Store());
      try {
        final node = await _mention(journal);
        final state = journal.editor.editorState;
        final before = jsonEncode(state.document.toJson());
        final history = state.undoManager.undoStack.last;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                throw PlatformException(code: 'denied');
              }
              return null;
            });
        await expectLater(
          journal.copySelection(_select(journal, node), cut: true),
          throwsA(isA<PlatformException>()),
        );
        expect(jsonEncode(state.document.toJson()), before);
        expect(state.undoManager.undoStack.last, same(history));
      } finally {
        await journal.close();
      }
    },
  );

  for (final change in [
    'edit',
    'format',
    'selection',
    'selection-restored',
    'selection-cleared',
    'selection-cleared-restored',
    'readonly',
    'readonly-restored',
    'close',
  ]) {
    test('pending clipboard cut does not delete after $change', () async {
      final journal = await _open(_Store());
      final gate = Completer<void>();
      try {
        final node = await _mention(journal);
        final state = journal.editor.editorState;
        final selected = _select(journal, node);
        final original = node.delta!.toPlainText();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') await gate.future;
              return null;
            });
        final pending = journal.copySelection(selected, cut: true);
        final expected = expectLater(pending, throwsStateError);
        if (change == 'edit') {
          await state.apply(
            state.transaction..insertText(node, node.delta!.length, '新'),
          );
        }
        if (change == 'format') {
          await state.apply(
            state.transaction..formatText(node, 0, 1, {'bold': true}),
          );
        }
        if (change == 'selection') {
          state.selection = Selection.collapsed(
            Position(path: node.path, offset: node.delta!.length),
          );
        }
        if (change == 'selection-restored') {
          state.selection = Selection.collapsed(
            Position(path: node.path, offset: node.delta!.length),
          );
          state.selection = selected;
        }
        if (change == 'selection-cleared') state.selection = null;
        if (change == 'selection-cleared-restored') {
          state.selection = null;
          state.selection = selected;
        }
        if (change == 'readonly') state.editable = false;
        if (change == 'readonly-restored') {
          state.editable = false;
          state.editable = true;
        }
        if (change == 'close') await journal.close();
        gate.complete();
        await expected;
        if (change != 'close') {
          expect(
            node.delta!.toPlainText(),
            change == 'edit' ? '$original新' : original,
          );
        }
      } finally {
        if (!gate.isCompleted) gate.complete();
        await journal.close();
      }
    });
  }

  test(
    'cut refuses readable expansion beyond paste capacity without deleting references',
    () async {
      final journal = await _open(_Store());
      try {
        final state = journal.editor.editorState;
        final node = await _mention(journal);
        await state.apply(
          state.transaction..insertText(
            node,
            node.delta!.length,
            'x' * (journalConfiguration.maxCharacters - node.delta!.length),
          ),
        );
        final before = node.delta!.toJson();
        await expectLater(
          journal.copySelection(_select(journal, node), cut: true),
          throwsStateError,
        );
        expect(node.delta!.toJson(), before);
      } finally {
        await journal.close();
      }
    },
  );

  test('cross section copy and cut preserve source and clipboard', () async {
    final journal = await _open(_Store());
    try {
      final node = await _mention(journal);
      await journal.addSection('reflection');
      final state = journal.editor.editorState;
      final before = jsonEncode(state.document.toJson());
      final selection = Selection(
        start: Position(path: node.path),
        end: Position(path: [1, 0]),
      );
      state.selection = selection;
      await AppFlowyClipboard.setData(text: '保留');
      for (final cut in [false, true]) {
        await expectLater(
          journal.copySelection(selection, cut: cut),
          throwsStateError,
        );
        expect(jsonEncode(state.document.toJson()), before);
        expect(AppFlowyClipboard.lastText, '保留');
      }
    } finally {
      await journal.close();
    }
  });

  test('external bare object clipboard remains rejected atomically', () async {
    final journal = await _open(_Store());
    try {
      final node = await _mention(journal);
      final before = node.delta!.toJson();
      _select(journal, node);
      AppFlowyClipboard.mockSetData(
        const AppFlowyClipboardData(text: '\uFFFC forged'),
      );
      await expectLater(journal.pasteFromClipboard(), throwsStateError);
      expect(node.delta!.toJson(), before);
    } finally {
      await journal.close();
    }
  });
}
