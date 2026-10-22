import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/guidance_entries.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/guidance_people.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_input.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_store.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_surface.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用JSON往返隔离正文快照，模拟保存后重新打开的本地存储。
final class _MemoryStore implements JournalStore {
  /// 最新保存内容，null表示首次打开。
  JournalDraft? saved;

  /// 读取独立快照，不共享正在编辑的文档。
  @override
  Future<JournalDraft?> read() async =>
      saved == null ? null : JournalDraft.fromJson(saved!.toJson());

  /// 保存[draft]的独立副本，不保留编辑器引用。
  @override
  Future<void> write(JournalDraft draft) async =>
      saved = JournalDraft.fromJson(draft.toJson());
}

/// 测试提及身份与名称，不访问真实组织或用户数据。
const _person = GuidancePerson(id: 'input-person', name: '张三');

/// 打开真实会话并插入单个提及；[tester]承载生产编辑视图，[store]用于持久化往返。
/// [bold]默认false，true为对象增加加粗以验证身份清理不影响普通格式继承。
Future<LocalJournalController> _mount(
  WidgetTester tester,
  _MemoryStore store, {
  bool bold = false,
}) async {
  final journal = await LocalJournalController.open(
    store: store,
    saveDelay: const Duration(days: 1),
  );
  final state = journal.editor.editorState;
  state.selection = Selection.collapsed(Position(path: [0, 0]));
  await journal.insertPeople(journal.captureInsertionTarget()!, const [
    _person,
  ]);
  if (bold) {
    await state.apply(
      state.transaction
        ..formatText(state.getNodeAtPath([0, 0])!, 0, 1, {'bold': true}),
      skipHistoryDebounce: true,
    );
  }
  state.undoManager.undoStack.clear();
  state.undoManager.redoStack.clear();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: JournalSurface(
          editorState: state,
          preview: false,
          header: const SizedBox(),
        ),
      ),
    ),
  );
  await tester.pump();
  return journal;
}

/// 从[tester]挂载的生产键盘服务读取真实IME入口。
KeyboardServiceWidgetState _keyboard(WidgetTester tester) => tester
    .state<KeyboardServiceWidgetState>(find.byType(KeyboardServiceWidget));

/// 在[tester]移除正文视图后等待[journal]保存和关闭，避免资源超过路由生命周期。
Future<void> _unmount(
  WidgetTester tester,
  LocalJournalController journal,
) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
  await tester.runAsync(journal.close);
}

/// 对真实IME的插入、替换、合成及持久化进行回归，不以直接设置正文代替输入。
void main() {
  for (final bold in [false, true]) {
    testWidgets(
      'IME insertion beside mention preserves identity and inherited style: bold=$bold',
      (tester) async {
        final store = _MemoryStore();
        final journal = await _mount(tester, store, bold: bold);
        final state = journal.editor.editorState;
        final node = state.getNodeAtPath([0, 0])!;
        try {
          final before = node.delta!.toJson();
          state.selection = Selection.collapsed(
            Position(path: [0, 0], offset: 1),
          );
          await tester.pump();
          await _keyboard(tester).textInputService.apply([
            const TextEditingDeltaInsertion(
              oldText: ' \uFFFC ',
              textInserted: '新',
              insertionOffset: 2,
              selection: TextSelection.collapsed(offset: 3),
              composing: TextRange.empty,
            ),
          ]);
          expect(node.delta!.toPlainText(), '\uFFFC新 ');
          expect(
            readGuidanceMention(
              node.delta!.slice(0, 1).single.attributes!,
            ).toJson(),
            _person.toJson(),
          );
          final inserted = node.delta!.slice(1, 2).single;
          expect(inserted.attributes?[guidanceMentionAttribute], isNull);
          expect(inserted.attributes?['bold'] == true, bold);
          validateJournalDocument(state.document);
          final after = node.delta!.toJson();
          state.undoManager.undo();
          await tester.pump();
          expect(node.delta!.toJson(), before);
          state.undoManager.redo();
          await tester.pump();
          expect(node.delta!.toJson(), after);
          expect(await tester.runAsync(journal.flush), isTrue);
          final restored = Document.fromJson(
            jsonDecode(store.saved!.documentJson) as Map<String, dynamic>,
          );
          try {
            validateJournalDocument(restored);
            expect(restored.nodeAtPath([0, 0])!.delta!.toJson(), after);
          } finally {
            restored.dispose();
          }
        } finally {
          await _unmount(tester, journal);
        }
      },
    );

    testWidgets(
      'IME replacing selected mention keeps normal text and undo restores object: bold=$bold',
      (tester) async {
        final journal = await _mount(tester, _MemoryStore(), bold: bold);
        final state = journal.editor.editorState;
        final node = state.getNodeAtPath([0, 0])!;
        try {
          final before = node.delta!.toJson();
          state.selection = Selection.single(
            path: [0, 0],
            startOffset: 0,
            endOffset: 1,
          );
          await tester.pump();
          await _keyboard(tester).textInputService.apply([
            const TextEditingDeltaReplacement(
              oldText: ' \uFFFC ',
              replacementText: '新',
              replacedRange: TextRange(start: 1, end: 2),
              selection: TextSelection.collapsed(offset: 2),
              composing: TextRange.empty,
            ),
          ]);
          expect(node.delta!.toPlainText(), '新 ');
          final inserted = node.delta!.slice(0, 1).single;
          expect(inserted.attributes?[guidanceMentionAttribute], isNull);
          expect(inserted.attributes?['bold'] == true, bold);
          validateJournalDocument(state.document);
          final after = node.delta!.toJson();
          state.undoManager.undo();
          await tester.pump();
          expect(node.delta!.toJson(), before);
          expect(
            readGuidanceMention(
              node.delta!.slice(0, 1).single.attributes!,
            ).toJson(),
            _person.toJson(),
          );
          state.undoManager.redo();
          await tester.pump();
          expect(node.delta!.toJson(), after);
        } finally {
          await _unmount(tester, journal);
        }
      },
    );
  }

  testWidgets(
    'IME backward replacement preserves surrounding styles and original object history',
    (tester) async {
      final journal = await _mount(tester, _MemoryStore(), bold: true);
      final state = journal.editor.editorState;
      final node = state.getNodeAtPath([0, 0])!;
      try {
        await state.apply(
          state.transaction
            ..insertText(node, 1, '后文', attributes: {'italic': true}),
          skipHistoryDebounce: true,
        );
        state.undoManager.undoStack.clear();
        state.undoManager.redoStack.clear();
        final before = node.delta!.toJson();
        state.selection = Selection.single(
          path: [0, 0],
          startOffset: 1,
          endOffset: 0,
        );
        await tester.pump();
        await _keyboard(tester).textInputService.apply([
          const TextEditingDeltaReplacement(
            oldText: ' \uFFFC后文 ',
            replacementText: '新',
            replacedRange: TextRange(start: 1, end: 2),
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange.empty,
          ),
        ]);
        expect(node.delta!.toPlainText(), '新后文 ');
        expect(node.delta!.slice(0, 1).single.attributes?['bold'], isTrue);
        expect(node.delta!.slice(1, 3).single.attributes?['italic'], isTrue);
        validateJournalDocument(state.document);
        state.undoManager.undo();
        await tester.pump();
        expect(node.delta!.toJson(), before);
        state.undoManager.redo();
        await tester.pump();
        expect(node.delta!.toPlainText(), '新后文 ');
        validateJournalDocument(state.document);
      } finally {
        await _unmount(tester, journal);
      }
    },
  );

  testWidgets(
    'IME composing insertion and conversion beside mention remain editable',
    (tester) async {
      final journal = await _mount(tester, _MemoryStore());
      final state = journal.editor.editorState;
      try {
        state.selection = Selection.collapsed(
          Position(path: [0, 0], offset: 1),
        );
        await tester.pump();
        final keyboard = _keyboard(tester);
        await keyboard.textInputService.apply([
          const TextEditingDeltaInsertion(
            oldText: ' \uFFFC ',
            textInserted: 'xin',
            insertionOffset: 2,
            selection: TextSelection.collapsed(offset: 5),
            composing: TextRange(start: 2, end: 5),
          ),
        ]);
        expect(state.getNodeAtPath([0, 0])!.delta!.toPlainText(), '\uFFFCxin ');
        await keyboard.textInputService.apply([
          const TextEditingDeltaReplacement(
            oldText: ' \uFFFCxin ',
            replacementText: '新',
            replacedRange: TextRange(start: 2, end: 5),
            selection: TextSelection.collapsed(offset: 3),
            composing: TextRange.empty,
          ),
        ]);
        expect(state.getNodeAtPath([0, 0])!.delta!.toPlainText(), '\uFFFC新 ');
        validateJournalDocument(state.document);
      } finally {
        await _unmount(tester, journal);
      }
    },
  );

  test(
    'normalization preserves validation evidence outside actual mention input',
    () {
      final state = EditorState.blank(withInitialText: true);
      try {
        final node = state.getNodeAtPath([0])!;
        state.selection = Selection.collapsed(Position(path: [0]));
        for (final text in ['伪造', '\uFFFC', '普通\uFFFC']) {
          final transaction = state.transaction
            ..insertText(
              node,
              0,
              text,
              attributes: guidanceMentionAttributes(_person),
            );
          final before = transaction.operations.single.toJson();
          normalizeJournalTextInput(state, transaction);
          expect(transaction.operations.single.toJson(), before);
        }
      } finally {
        state.dispose();
      }
    },
  );

  test(
    'incremental input normalization is idempotent and keeps an exact inverse',
    () {
      final source = guidanceMentionDelta(const [_person]);
      final state = EditorState(
        document: Document(
          root: Node(
            type: 'page',
            children: [paragraphNode(delta: source)],
          ),
        ),
      );
      try {
        state.selection = Selection.collapsed(Position(path: [0], offset: 1));
        final delta = Delta()
          ..retain(1)
          ..insert(
            '新',
            attributes: {...guidanceMentionAttributes(_person), 'bold': true},
          );
        final transaction = state.transaction
          ..add(UpdateTextOperation([0], delta, delta.invert(source)));
        normalizeJournalTextInput(state, transaction);
        final normalized = transaction.operations.single as UpdateTextOperation;
        final after = source.compose(normalized.delta);
        expect(after.toPlainText(), '\uFFFC新 ');
        expect(after.slice(1, 2).single.attributes, {'bold': true});
        expect(after.compose(normalized.inverted).toJson(), source.toJson());
        final beforeSecondCall = transaction.operations.single.toJson();
        normalizeJournalTextInput(state, transaction);
        expect(transaction.operations.single.toJson(), beforeSecondCall);
        expect(validJournalDelta(after, complete: true), isTrue);
      } finally {
        state.dispose();
      }
    },
  );

  test(
    'object insertions and mismatched identities keep strict validation evidence',
    () {
      final source = guidanceMentionDelta(const [_person]);
      final state = EditorState(
        document: Document(
          root: Node(
            type: 'page',
            children: [paragraphNode(delta: source)],
          ),
        ),
      );
      try {
        final node = state.getNodeAtPath([0])!;
        state.selection = Selection.collapsed(Position(path: [0], offset: 1));
        for (final delta in [
          Delta()
            ..insert('\uFFFC', attributes: guidanceMentionAttributes(_person)),
          Delta()..insert(
            '\uFFFC伪造',
            attributes: guidanceMentionAttributes(_person),
          ),
          Delta()..insert(
            '伪造',
            attributes: guidanceMentionAttributes(
              const GuidancePerson(id: 'other', name: '李四'),
            ),
          ),
          Delta()
            ..insert('伪造', attributes: {guidanceMentionAttribute: '{invalid'}),
        ]) {
          final transaction = state.transaction
            ..insertTextDelta(node, 1, delta);
          final before = transaction.operations.single.toJson();
          normalizeJournalTextInput(state, transaction);
          expect(transaction.operations.single.toJson(), before);
        }
      } finally {
        state.dispose();
      }
    },
  );
}
