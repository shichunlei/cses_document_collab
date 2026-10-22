import 'fixtures.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_store.dart';
import 'dart:async';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
import 'package:flutter_test/flutter_test.dart';

/// 受控存储，记录保存顺序并注入磁盘失败或慢写入。
class _Store implements JournalStore {
  /// 最近落盘的独立快照。
  JournalDraft? value;

  /// 模拟磁盘失败，保留旧快照。
  bool fail = false;

  /// 慢写入闸门，由测试负责完成。
  Completer<void>? gate;

  /// 当前在途写入数。
  int active = 0;

  /// 用于检查同一文件的最大并发写入数。
  int maximumActive = 0;

  /// 按完成顺序保存的快照。
  final writes = <JournalDraft>[];

  /// 返回已持久化快照，不模拟丢失或自动修复。
  @override
  Future<JournalDraft?> read() async => value;

  /// 保存[draft]前等待gate；失败保留上一快照。
  @override
  Future<void> write(JournalDraft draft) async {
    active++;
    if (active > maximumActive) maximumActive = active;
    try {
      await gate?.future;
      if (fail) throw StateError('disk full');
      writes.add(draft);
      value = draft;
    } finally {
      active--;
    }
  }
}

/// 验证固定栏目、自动保存、慢写入、失败重试及历史恢复。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'three stable sections and date survive close and reopen on another day',
    () async {
      final store = _Store();
      final journal = await openTestJournal(
        store: store,
        now: DateTime(2026, 10, 22),
      );
      final state = journal.editor.editorState;
      expect(
        state.document.root.children.map((n) => n.attributes['section']),
        journalSections,
      );
      for (var i = 0; i < 3; i++) {
        await state.apply(
          state.transaction..insertText(
            state.getNodeAtPath([i, 0])!,
            0,
            ['完成了今日目标', '今天的感悟', '复盘与自检'][i],
          ),
        );
      }
      expect(journal.dirty, isTrue);
      expect(await journal.flush(), isTrue);
      expect(journal.dirty, isFalse);
      final id = store.value!.id;
      await journal.close();
      final reopened = await openTestJournal(
        store: store,
        now: DateTime(2026, 11, 1),
      );
      expect(reopened.date, '2026-10-22');
      expect(store.value!.id, id);
      expect(
        reopened.editor.editorState.getNodeAtPath([2, 0])!.delta!.toPlainText(),
        '复盘与自检',
      );
      await reopened.close();
    },
  );

  test('auto save debounce persists without an explicit save button', () async {
    final store = _Store();
    final journal = await openTestJournal(
      store: store,
      saveDelay: const Duration(milliseconds: 10),
    );
    journal.setDate('2026-10-21');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(store.value!.date, '2026-10-21');
    expect(journal.dirty, isFalse);
    await journal.close();
  });

  test(
    'slow saves serialize and include edits arriving during the first write',
    () async {
      final store = _Store()..gate = Completer<void>();
      final journal = await openTestJournal(store: store);
      final saving = journal.flush();
      final state = journal.editor.editorState;
      await state.apply(
        state.transaction
          ..insertText(state.getNodeAtPath([1, 0])!, 0, '迟到的新内容'),
      );
      journal.setDate('2026-10-20');
      final joined = journal.flush();
      expect(identical(saving, joined), isTrue);
      expect(journal.dirty, isTrue);
      store.gate!.complete();
      expect(await saving, isTrue);
      expect(store.maximumActive, 1);
      expect(store.writes, hasLength(2));
      expect(store.value!.date, '2026-10-20');
      expect(store.value!.documentJson, contains('迟到的新内容'));
      expect(journal.dirty, isFalse);
      await journal.close();
    },
  );

  test(
    'save failure retains dirty content and retry saves the latest revision',
    () async {
      final store = _Store();
      final journal = await openTestJournal(store: store);
      await journal.flush();
      final old = store.value;
      store.fail = true;
      final state = journal.editor.editorState;
      await state.apply(
        state.transaction
          ..insertText(state.getNodeAtPath([0, 0])!, 0, '失败时仍保留'),
      );
      expect(await journal.flush(), isFalse);
      expect(journal.error, isNotNull);
      expect(journal.dirty, isTrue);
      expect(identical(store.value, old), isTrue);
      store.fail = false;
      expect(await journal.flush(), isTrue);
      expect(journal.error, isNull);
      expect(store.value!.documentJson, contains('失败时仍保留'));
      await journal.close();
    },
  );

  test(
    'section deletion, reordering, unsupported objects and last-leaf deletion are atomic rejections',
    () async {
      final journal = await openTestJournal(store: _Store());
      final state = journal.editor.editorState;
      final before = jsonEncode(state.document.toJson());
      final attempts = [
        state.transaction..deleteNode(state.document.root.children.first),
        state.transaction..updateNode(state.document.root.children.first, {
          'section': 'self-check',
        }),
        state.transaction..deleteNode(state.getNodeAtPath([1, 0])!),
        state.transaction
          ..insertNode([1, 1], Node(type: 'image', attributes: {'url': 'x'})),
        state.transaction
          ..insertText(state.getNodeAtPath([1, 0])!, 0, '\uFFFC'),
        state.transaction..insertNode([0], paragraphNode(text: 'outside')),
      ];
      for (final transaction in attempts) {
        expect(state.canApplyTransaction(transaction), isFalse);
        await state.apply(transaction);
        expect(jsonEncode(state.document.toJson()), before);
      }
      expect(state.undoManager.undoStack.isEmpty, isTrue);
      await journal.close();
    },
  );

  test(
    'paragraph splitting and list conversion retain undo and redo inside their section',
    () async {
      final journal = await openTestJournal(store: _Store());
      final state = journal.editor.editorState;
      state.selection = Selection.collapsed(Position(path: [0, 0]));
      expect(
        await applyDocumentBlockShortcut(
          state,
          state.selection!,
          TodoListBlockKeys.type,
        ),
        isTrue,
      );
      expect(state.getNodeAtPath([0, 0])!.type, TodoListBlockKeys.type);
      final undo = state.undoManager.undoStack.last.toTransaction(state);
      expect(
        state.canApplyTransaction(undo),
        isTrue,
        reason: jsonEncode(undo.toJson()),
      );
      state.undoManager.undo();
      expect(state.getNodeAtPath([0, 0])!.type, ParagraphBlockKeys.type);
      state.undoManager.redo();
      expect(state.getNodeAtPath([0, 0])!.type, TodoListBlockKeys.type);
      await state.apply(
        state.transaction..insertText(state.getNodeAtPath([0, 0])!, 0, '今天的记录'),
        skipHistoryDebounce: true,
      );
      state.selection = Selection.collapsed(Position(path: [0, 0], offset: 5));
      expect(await handleDocumentParagraphEnter(state), isTrue);
      expect(state.document.root.children.first.children.length, 2);
      expect(
        state.document.root.children.map((n) => n.attributes['section']),
        journalSections,
      );
      await journal.close();
    },
  );

  test(
    'unsupported persisted versions and malformed dates never become blank drafts',
    () async {
      final draft = JournalDraft.blank(DateTime(2026, 10, 22));
      expect(
        () => JournalDraft.fromJson({...draft.toJson(), 'schemaVersion': 3}),
        throwsFormatException,
      );
      expect(
        () => JournalDraft.fromJson({...draft.toJson(), 'date': '2026-02-30'}),
        throwsFormatException,
      );
      final corrupt = _Store()
        ..value = JournalDraft(
          id: draft.id,
          date: draft.date,
          createdAt: draft.createdAt,
          updatedAt: draft.updatedAt,
          timezoneOffsetMinutes: 0,
          documentJson: jsonEncode(Document.blank().toJson()),
        );
      await expectLater(openTestJournal(store: corrupt), throwsFormatException);
      expect(corrupt.writes, isEmpty);
    },
  );

  test('closing waits for the last write and rejects late mutations', () async {
    final store = _Store()..gate = Completer<void>();
    final journal = await openTestJournal(store: store);
    final closing = journal.close();
    expect(identical(closing, journal.close()), isTrue);
    expect(journal.closed, isTrue);
    journal.setDate('2026-01-01');
    store.gate!.complete();
    await closing;
    expect(journal.editor.closed, isTrue);
    expect(store.value, isNotNull);
  });

  test(
    'synchronous dispose releases listeners and still completes pending persistence',
    () async {
      final store = _Store()..gate = Completer<void>();
      final journal = await openTestJournal(store: store);
      var notifications = 0;
      journal.addListener(() => notifications++);
      journal.dispose();
      final before = notifications;
      store.gate!.complete();
      await journal.close();
      expect(notifications, before);
      expect(journal.editor.closed, isTrue);
      expect(store.value, isNotNull);
    },
  );
}
