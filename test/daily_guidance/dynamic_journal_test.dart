import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/guidance_entries.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/guidance_people.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_editing.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_store.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// 保存独立JSON往返快照，避免测试存储与正在编辑的树共享可变对象。
final class _MemoryJournalStore implements JournalStore {
  /// 最近成功写入或显式预置的快照，null表示尚无草稿。
  JournalDraft? saved;

  /// 返回独立恢复的快照；不创建或覆盖缺失草稿。
  @override
  Future<JournalDraft?> read() async =>
      saved == null ? null : JournalDraft.fromJson(saved!.toJson());

  /// 为[draft]保存独立往返快照，模拟成功原子提交后的可重开状态。
  @override
  Future<void> write(JournalDraft draft) async =>
      saved = JournalDraft.fromJson(draft.toJson());
}

/// 创建可独立关闭的真实会话；[store]可复用以验证保存重开，默认使用新的内存存储。
Future<LocalJournalController> _open({_MemoryJournalStore? store}) =>
    LocalJournalController.open(
      store: store ?? _MemoryJournalStore(),
      now: DateTime(2026, 10, 22),
      saveDelay: const Duration(days: 1),
    );

/// 读取[journal]的可见栏目语义顺序，不依赖节点路径或临时ID。
List<String> _visibleSections(LocalJournalController journal) => journal
    .editor
    .editorState
    .document
    .root
    .children
    .map((node) => node.attributes['section'] as String)
    .toList();

/// 按语义身份读取[journal]的[kind]可见栏目；缺失时直接使测试失败。
Node _section(LocalJournalController journal, String kind) => journal
    .editor
    .editorState
    .document
    .root
    .children
    .singleWhere((node) => node.attributes['section'] == kind);

/// 从借用的[node]读取所有原子引用快照，保留在正文中的顺序。
List<GuidancePerson> _mentions(Node node) => node.delta!
    .whereType<TextInsert>()
    .where((insert) => insert.attributes?[guidanceMentionAttribute] != null)
    .expand(
      (insert) => insert.text.runes
          .where((rune) => rune == 0xfffc)
          .map((_) => readGuidanceMention(insert.attributes!)),
    )
    .toList();

/// 为借用的[journal]在[selection]处捕获真实目标，拒绝意外的空或跨段目标。
GuidanceInsertionTarget _target(
  LocalJournalController journal,
  Selection selection,
) {
  journal.editor.editorState.selection = selection;
  return journal.captureInsertionTarget()!;
}

/// 在借用的[node]末尾定位[journal]选区，用于验证当前业务行内的后续操作。
GuidanceInsertionTarget _endTarget(LocalJournalController journal, Node node) =>
    _target(
      journal,
      Selection.collapsed(
        Position(path: node.path, offset: node.delta!.length),
      ),
    );

/// 用独立的[record]和[closed]叶子构造合法持久快照；节点所有权转交临时文档后释放。
JournalDraft _seed({required List<Node> record, List<Node> closed = const []}) {
  final blank = JournalDraft.blank(DateTime(2026, 10, 22));
  final document = Document(
    root: Node(
      type: PageBlockKeys.type,
      attributes: {
        if (closed.isNotEmpty)
          journalClosedSectionsAttribute: closed
              .map((node) => node.toJson())
              .toList(),
      },
      children: [
        Node(
          type: journalSectionType,
          attributes: {'section': 'record'},
          children: record,
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
    for (final node in closed) {
      node.dispose();
    }
  }
}

/// 构建[count]个合法原子引用，引用本身使用不同的真实身份，尾部空格计入正文长度。
Delta _referenceDelta(int count) {
  final delta = Delta();
  for (var i = 0; i < count; i++) {
    delta.addAll(
      guidanceMentionDelta([GuidancePerson(id: 'person-$i', name: '用户$i')]),
    );
  }
  return delta;
}

/// 验证宿主业务能力使用真实事务、撤销与草稿保存，不依赖协同包私有实现。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const person = GuidancePerson(id: 'u1', name: '张三', department: '研发');

  test(
    'a fresh draft shows only record and optional sections follow add order without duplicates',
    () async {
      final journal = await _open();
      try {
        expect(_visibleSections(journal), ['record']);
        expect(journal.date, '2026-10-22');
        await journal.addSection('self-check');
        await journal.addSection('reflection');
        await journal.addSection('self-check');
        await journal.addSection('unknown');
        await journal.closeSection('record');
        expect(_visibleSections(journal), [
          'record',
          'self-check',
          'reflection',
        ]);
        expect(
          closedJournalSections(journal.editor.editorState.document),
          isEmpty,
        );
      } finally {
        await journal.close();
      }
    },
  );

  test(
    'first-time section addition has an independent undo and redo',
    () async {
      final journal = await _open();
      final state = journal.editor.editorState;
      try {
        final before = jsonEncode(state.document.toJson());
        await journal.addSection('reflection');
        expect(_visibleSections(journal), ['record', 'reflection']);
        final added = jsonEncode(state.document.toJson());
        state.undoManager.undo();
        expect(jsonEncode(state.document.toJson()), before);
        state.undoManager.redo();
        expect(jsonEncode(state.document.toJson()), added);
        expect(_visibleSections(journal), ['record', 'reflection']);
      } finally {
        await journal.close();
      }
    },
  );

  test(
    'closing a filled section preserves its text and formatting through undo and reopening',
    () async {
      final store = _MemoryJournalStore();
      var journal = await _open(store: store);
      try {
        await journal.addSection('reflection');
        final state = journal.editor.editorState;
        final node = _section(journal, 'reflection').children.single;
        await state.apply(
          state.transaction..updateNode(node, {
            blockComponentDelta:
                (Delta()..insert(
                      '今天的感悟',
                      attributes: {AppFlowyRichTextKeys.bold: true},
                    ))
                    .toJson(),
          }),
          skipHistoryDebounce: true,
        );
        final reflection = node.toJson();
        await journal.closeSection('reflection');
        expect(_visibleSections(journal), ['record']);
        expect(
          closedJournalSections(state.document).single.children.single.toJson(),
          reflection,
        );
        state.undoManager.undo();
        expect(_visibleSections(journal), ['record', 'reflection']);
        expect(
          _section(journal, 'reflection').children.single.toJson(),
          reflection,
        );
        state.undoManager.redo();
        expect(_visibleSections(journal), ['record']);
        expect(await journal.flush(), isTrue);
        final identity = store.saved!.id;
        await journal.close();
        journal = await _open(store: store);
        expect(_visibleSections(journal), ['record']);
        expect(store.saved!.id, identity);
        await journal.addSection('reflection');
        expect(
          _section(journal, 'reflection').children.single.toJson(),
          reflection,
        );
        expect(
          closedJournalSections(journal.editor.editorState.document),
          isEmpty,
        );
      } finally {
        await journal.close();
      }
    },
  );

  test(
    'inline mentions replace the captured range and deduplicate by type and id with undo and redo',
    () async {
      final journal = await _open();
      final state = journal.editor.editorState;
      try {
        final node = _section(journal, 'record').children.single;
        await state.apply(
          state.transaction..insertText(node, 0, '今天找甲处理'),
          skipHistoryDebounce: true,
        );
        final before = node.delta!.toJson();
        final target = _target(
          journal,
          Selection(
            start: Position(path: node.path, offset: 3),
            end: Position(path: node.path, offset: 4),
          ),
        );
        await journal.insertPeople(target, const [
          GuidancePerson(id: 'same-id', name: '同名用户'),
          GuidancePerson(id: 'same-id', name: '重复用户'),
          GuidancePerson(id: 'same-id', name: '同名部门', type: 'department'),
        ]);
        expect(node.delta!.toPlainText(), '今天找\uFFFC \uFFFC 处理');
        expect(_mentions(node).map((mention) => mention.identity), [
          'user:same-id',
          'department:same-id',
        ]);
        expect(_mentions(node).map((mention) => mention.name), [
          '同名用户',
          '同名部门',
        ]);
        expect(state.selection!.end.offset, 7, reason: '插入后光标应位于引用之后、原后缀之前');
        final after = node.delta!.toJson();
        state.undoManager.undo();
        expect(node.delta!.toJson(), before);
        state.undoManager.redo();
        expect(node.delta!.toJson(), after);
        expect(state.selection!.end.offset, 7);
        expect(await journal.flush(), isTrue);
      } finally {
        await journal.close();
      }
    },
  );

  test(
    'mention identity and name snapshots survive save and reopen without organization children',
    () async {
      final store = _MemoryJournalStore();
      var journal = await _open(store: store);
      try {
        final node = _section(journal, 'record').children.single;
        await journal.insertPeople(_endTarget(journal, node), const [
          person,
          GuidancePerson(
            id: 'd1',
            name: '整个部门',
            type: 'department',
            children: [person],
          ),
        ]);
        expect(await journal.flush(), isTrue);
        await journal.close();
        journal = await _open(store: store);
        final restored = _mentions(_section(journal, 'record').children.single);
        expect(restored.map((item) => item.identity), [
          'user:u1',
          'department:d1',
        ]);
        expect(restored.map((item) => item.name), ['张三', '整个部门']);
        expect(restored.every((item) => item.children.isEmpty), isTrue);
      } finally {
        await journal.close();
      }
    },
  );

  test(
    'task conversion preserves existing rich text as one editable entry and supports undo',
    () async {
      final journal = await _open();
      final state = journal.editor.editorState;
      try {
        final node = _section(journal, 'record').children.single;
        await state.apply(
          state.transaction..updateNode(node, {
            blockComponentDelta:
                (Delta()..insert(
                      '完成原有事项',
                      attributes: {AppFlowyRichTextKeys.bold: true},
                    ))
                    .toJson(),
          }),
          skipHistoryDebounce: true,
        );
        final original = node.delta!.toJson();
        await journal.insertPeople(_endTarget(journal, node), const [
          person,
          person,
        ], kind: 'task');
        final entry = _section(journal, 'record').children.single;
        expect(entry.attributes[guidanceEntryAttribute], 'task');
        expect(entry.attributes['guidance_done'], isFalse);
        expect(entry.delta!.toPlainText(), '\uFFFC 完成原有事项');
        expect(entry.delta!.slice(2).toJson(), original);
        expect(_mentions(entry), hasLength(1));
        state.undoManager.undo();
        expect(
          _section(journal, 'record').children.single.delta!.toJson(),
          original,
        );
        expect(
          _section(
            journal,
            'record',
          ).children.single.attributes[guidanceEntryAttribute],
          isNull,
        );
        state.undoManager.redo();
        expect(
          _section(
            journal,
            'record',
          ).children.single.attributes[guidanceEntryAttribute],
          'task',
        );
      } finally {
        await journal.close();
      }
    },
  );

  test(
    'tasks, help and pilot entries stay inside reflection and each help or pilot appends a row',
    () async {
      final journal = await _open();
      final state = journal.editor.editorState;
      try {
        await journal.addSection('reflection');
        var node = _section(journal, 'reflection').children.single;
        await state.apply(
          state.transaction..insertText(node, 0, '原行内容'),
          skipHistoryDebounce: true,
        );
        await journal.insertPeople(_endTarget(journal, node), const [
          person,
        ], kind: 'task');
        node = _section(journal, 'reflection').children.last;
        await journal.insertPeople(_endTarget(journal, node), const [
          person,
        ], kind: 'help');
        node = _section(journal, 'reflection').children.last;
        await journal.insertPeople(_endTarget(journal, node), const [
          person,
        ], kind: 'pilot');
        final rows = _section(journal, 'reflection').children;
        expect(rows.map((item) => item.attributes[guidanceEntryAttribute]), [
          'task',
          'help',
          'pilot',
        ]);
        expect(rows.first.delta!.toPlainText(), '\uFFFC 原行内容');
        expect(rows.skip(1).map((item) => item.delta!.toPlainText()), [
          '\uFFFC ',
          '\uFFFC ',
        ]);
        expect(
          _section(journal, 'record').children.single.delta!.isEmpty,
          isTrue,
        );
      } finally {
        await journal.close();
      }
    },
  );

  for (final kind in ['task', 'help', 'pilot']) {
    test(
      'Enter ends a $kind entry without inheriting business attributes and is undoable',
      () async {
        final journal = await _open();
        final state = journal.editor.editorState;
        try {
          var node = _section(journal, 'record').children.single;
          await journal.insertPeople(_endTarget(journal, node), const [
            person,
          ], kind: kind);
          node = _section(journal, 'record').children.last;
          await state.apply(
            state.transaction..insertText(node, node.delta!.length, '条目正文'),
            skipHistoryDebounce: true,
          );
          final before = node.toJson();
          final count = _section(journal, 'record').children.length;
          state.selection = Selection.collapsed(
            Position(path: node.path, offset: node.delta!.length),
          );
          expect(await journalParagraphEnter.handler(state), isTrue);
          final continuation = _section(journal, 'record').children.last;
          expect(_section(journal, 'record').children.length, count + 1);
          expect(continuation.type, ParagraphBlockKeys.type);
          expect(continuation.delta!.isEmpty, isTrue);
          expect(
            continuation.attributes.keys.where(
              (key) => key.startsWith('guidance_'),
            ),
            isEmpty,
          );
          state.undoManager.undo();
          expect(_section(journal, 'record').children.length, count);
          expect(_section(journal, 'record').children.last.toJson(), before);
          state.undoManager.redo();
          expect(
            _section(
              journal,
              'record',
            ).children.last.attributes[guidanceEntryAttribute],
            isNull,
          );
        } finally {
          await journal.close();
        }
      },
    );
  }

  test(
    'late mention targets reject text changes, date changes, another session and closure',
    () async {
      final first = await _open();
      final other = await _open();
      try {
        final node = _section(first, 'record').children.single;
        var target = _endTarget(first, node);
        await first.editor.editorState.apply(
          first.editor.editorState.transaction..insertText(node, 0, '已修改'),
        );
        await expectLater(
          first.insertPeople(target, const [person]),
          throwsStateError,
        );
        expect(_mentions(node), isEmpty);
        target = _endTarget(first, node);
        first.setDate('2026-10-21');
        await expectLater(
          first.insertPeople(target, const [person]),
          throwsStateError,
        );
        target = _endTarget(first, node);
        await expectLater(
          other.insertPeople(target, const [person]),
          throwsStateError,
        );
        expect(
          _section(other, 'record').children.single.delta!.isEmpty,
          isTrue,
        );
        await first.close();
        await expectLater(
          first.insertPeople(target, const [person]),
          throwsStateError,
        );
      } finally {
        await first.close();
        await other.close();
      }
    },
  );

  test(
    'bare objects, unknown inline attributes and invalid mention objects are atomic rejections',
    () async {
      final journal = await _open();
      final state = journal.editor.editorState;
      try {
        final node = _section(journal, 'record').children.single;
        await state.apply(
          state.transaction..insertText(node, 0, '原文'),
          skipHistoryDebounce: true,
        );
        final before = jsonEncode(state.document.toJson());
        final deltas = [
          Delta()..insert('\uFFFC'),
          Delta()..insert('未知', attributes: {'unknown-attribute': true}),
          Delta()
            ..insert('普通文本', attributes: guidanceMentionAttributes(person)),
          Delta()..insert(
            '\uFFFC',
            attributes: {guidanceMentionAttribute: '{invalid'},
          ),
          Delta()..insert(
            '\uFFFC',
            attributes: {
              guidanceMentionAttribute: jsonEncode({
                'id': 'x',
                'name': '非法',
                'type': 'unknown',
              }),
            },
          ),
        ];
        for (final delta in deltas) {
          for (final replace in [true, false]) {
            final transaction = state.transaction;
            if (replace) {
              transaction.updateNode(node, {
                blockComponentDelta: delta.toJson(),
              });
            } else {
              transaction.insertTextDelta(node, node.delta!.length, delta);
            }
            expect(state.canApplyTransaction(transaction), isFalse);
            await state.apply(transaction);
            expect(jsonEncode(state.document.toJson()), before);
          }
        }
      } finally {
        await journal.close();
      }
    },
  );

  test(
    'the 500-reference budget accepts the last reference and rejects the next atomically',
    () async {
      final store = _MemoryJournalStore()
        ..saved = _seed(record: [paragraphNode(delta: _referenceDelta(499))]);
      final journal = await _open(store: store);
      try {
        final node = _section(journal, 'record').children.single;
        await journal.insertPeople(_endTarget(journal, node), const [person]);
        expect(_mentions(node), hasLength(500));
        final before = node.delta!.toJson();
        await expectLater(
          journal.insertPeople(_endTarget(journal, node), const [person]),
          throwsStateError,
        );
        expect(node.delta!.toJson(), before);
        final keyboardTransaction = journal.editor.editorState.transaction
          ..insertText(
            node,
            node.delta!.length,
            '\uFFFC',
            attributes: guidanceMentionAttributes(person),
          );
        expect(
          journal.editor.editorState.canApplyTransaction(keyboardTransaction),
          isFalse,
        );
        await journal.editor.editorState.apply(keyboardTransaction);
        expect(node.delta!.toJson(), before);
        expect(await journal.flush(), isTrue);
      } finally {
        await journal.close();
      }
    },
  );

  test(
    'references in closed sections remain part of the total budget',
    () async {
      final store = _MemoryJournalStore()
        ..saved = _seed(
          record: [paragraphNode()],
          closed: [
            Node(
              type: journalSectionType,
              attributes: {'section': 'reflection'},
              children: [paragraphNode(delta: _referenceDelta(500))],
            ),
          ],
        );
      final journal = await _open(store: store);
      try {
        final node = _section(journal, 'record').children.single;
        await expectLater(
          journal.insertPeople(_endTarget(journal, node), const [person]),
          throwsStateError,
        );
        expect(node.delta!.isEmpty, isTrue);
        await journal.addSection('reflection');
        expect(
          _mentions(_section(journal, 'reflection').children.single),
          hasLength(500),
        );
      } finally {
        await journal.close();
      }
    },
  );

  test('closed section text remains part of the character capacity', () async {
    final journal = await _open();
    final state = journal.editor.editorState;
    try {
      await journal.addSection('reflection');
      final reflection = _section(journal, 'reflection').children.single;
      await state.apply(
        state.transaction..insertText(
          reflection,
          0,
          'x' * (journalConfiguration.maxCharacters - 1),
        ),
      );
      await journal.closeSection('reflection');
      final node = _section(journal, 'record').children.single;
      var transaction = state.transaction..insertText(node, 0, '超额');
      expect(state.canApplyTransaction(transaction), isFalse);
      await state.apply(transaction);
      expect(node.delta!.isEmpty, isTrue);
      transaction = state.transaction..insertText(node, 0, '满');
      expect(state.canApplyTransaction(transaction), isTrue);
      await state.apply(transaction);
      expect(node.delta!.toPlainText(), '满');
      expect(await journal.flush(), isTrue);
    } finally {
      await journal.close();
    }
  });

  test('closed section leaves remain part of the block capacity', () async {
    final store = _MemoryJournalStore()
      ..saved = _seed(
        record: [paragraphNode()],
        closed: [
          Node(
            type: journalSectionType,
            attributes: {'section': 'reflection'},
            children: List.generate(
              journalConfiguration.maxBlocks - 1,
              (_) => paragraphNode(),
            ),
          ),
        ],
      );
    final journal = await _open(store: store);
    final state = journal.editor.editorState;
    try {
      final before = jsonEncode(state.document.toJson());
      final transaction = state.transaction
        ..insertNode([0, 1], paragraphNode(text: '超出块数'));
      expect(state.canApplyTransaction(transaction), isFalse);
      await state.apply(transaction);
      await expectLater(journal.addSection('self-check'), throwsStateError);
      expect(jsonEncode(state.document.toJson()), before);
      await journal.addSection('reflection');
      expect(
        _section(journal, 'reflection').children,
        hasLength(journalConfiguration.maxBlocks - 1),
      );
    } finally {
      await journal.close();
    }
  });
}
