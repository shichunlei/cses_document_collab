import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_blockcraft_codec.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_store.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// 探针独占的存储，以生产模型执行持久化往返，不访问用户目录。
class _Store implements JournalStore {
  /// 接管独立初值[draft]；后续写入均深拷贝。
  _Store(this.draft);

  /// 此会话持有的独立恢复值。
  JournalDraft draft;

  /// 返回生产解析器校验的独立草稿。
  @override
  Future<JournalDraft?> read() async => JournalDraft.fromJson(draft.toJson());

  /// 保存独立[value]，不持有编辑器。
  @override
  Future<void> write(JournalDraft value) async =>
      draft = JournalDraft.fromJson(value.toJson());
}

/// 将虚构[children]包装为独立桌面根块。
Map<String, dynamic> _root(List<Map<String, dynamic>> children) => {
  'id': 'root',
  'flavour': 'root',
  'nodeType': 'root',
  'props': <String, Object>{},
  'meta': <String, Object>{},
  'children': children,
};

/// 创建[id]标识的虚构空正文，[meta]承载业务或锁元数据。
Map<String, dynamic> _paragraph({
  String id = 'paragraph',
  Map<String, dynamic> meta = const {},
}) => {
  'id': id,
  'flavour': 'paragraph',
  'nodeType': 'editable',
  'props': <String, Object>{},
  'meta': meta,
  'children': <Object>[],
};

/// 创建带[locked]状态的虚构容器；[prefix]可在前方加入独立段落，验证重排后的路径。
Map<String, dynamic> _container({bool locked = true, bool prefix = false}) =>
    _root([
      if (prefix) _paragraph(id: 'prefix'),
      {
        'id': 'callout',
        'flavour': 'callout',
        'nodeType': 'block',
        'props': <String, Object>{},
        'meta': <String, Object>{if (locked) 'lock': 'user-demo'},
        'children': [_paragraph()],
      },
    ]);

/// 使用生产转换与宿主会话打开虚构[snapshot]；调用方负责关闭。
Future<LocalJournalController> _open(Map<String, dynamic> snapshot) =>
    LocalJournalController.open(
      store: _Store(
        JournalBlockCraftCodec.importSnapshot(
          snapshot,
          now: DateTime(2026, 10, 23),
        ),
      ),
    );

/// 验证业务身份持久化、双向转换和按事务顺序处理的锁保护。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final kind in ['help', 'pilot', 'task']) {
    test(
      'R1 imported $kind survives heading conversion, save/reopen and both JSON directions',
      () async {
        final snapshot = _root([
          _paragraph(
            meta: {
              'audit': 'demo',
              'mobileGuidance': {
                'version': 1,
                'role': 'content',
                'section': 'record',
                'business': {
                  'guidance_entry': kind,
                  'guidance_entry_id': 'entry-demo',
                  'guidance_done': false,
                },
              },
            },
          ),
        ]);
        final store = _Store(
          JournalBlockCraftCodec.importSnapshot(
            snapshot,
            now: DateTime(2026, 10, 23),
          ),
        );
        final journal = await LocalJournalController.open(store: store);
        try {
          final state = journal.editor.editorState;
          final selection = Selection.collapsed(Position(path: [0, 0]));
          state.selection = selection;
          expect(
            await applyDocumentBlockShortcut(
              state,
              selection,
              HeadingBlockKeys.type,
              headingLevel: 2,
            ),
            true,
          );
          expect(state.getNodeAtPath([0, 0])!.type, HeadingBlockKeys.type);
          expect(state.getNodeAtPath([0, 0])!.attributes['bc.id'], 'paragraph');
          state.undoManager.undo();
          await pumpEventQueue();
          expect(state.getNodeAtPath([0, 0])!.type, ParagraphBlockKeys.type);
          state.undoManager.redo();
          await pumpEventQueue();
          final heading = state.getNodeAtPath([0, 0])!;
          expect(heading.type, HeadingBlockKeys.type);
          await state.apply(
            state.transaction..insertText(
              heading,
              0,
              '双向转换修复验证',
              attributes: {'bold': true, 't:px': 24},
            ),
          );
          final exported = journal.exportBlockCraftSnapshot();
          final block = (exported['children'] as List).single as Map;
          expect(block['id'], 'paragraph');
          expect((block['meta'] as Map)['audit'], 'demo');
          final business =
              ((block['meta'] as Map)['mobileGuidance'] as Map)['business']
                  as Map;
          expect(business['guidance_entry_id'], 'entry-demo');
          expect(business['guidance_entry'], kind);
          expect(business['guidance_done'], false);
          final restoredDraft = JournalBlockCraftCodec.importSnapshot(
            jsonDecode(jsonEncode(exported)) as Map<String, dynamic>,
          );
          final restored = await LocalJournalController.open(
            store: _Store(restoredDraft),
          );
          try {
            final node = restored.editor.editorState.getNodeAtPath([0, 0])!;
            expect(node.type, HeadingBlockKeys.type);
            expect(node.attributes['guidance_entry_id'], 'entry-demo');
            expect(node.delta!.toPlainText(), '双向转换修复验证');
            expect(
              restored.exportBlockCraftSnapshot()['children'],
              exported['children'],
            );
          } finally {
            await restored.close();
          }
          expect(await journal.flush(), true);
          await journal.close();
          final reopened = await LocalJournalController.open(store: store);
          try {
            expect(
              reopened.exportBlockCraftSnapshot()['children'],
              exported['children'],
            );
          } finally {
            await reopened.close();
          }
          if (kind == 'help' &&
              const bool.fromEnvironment('GENERATE_BLOCKCRAFT_EXAMPLES')) {
            File(
              'docs/verification/blockcraft-json-exchange-20261023/fixed-journal-roundtrip.json',
            ).writeAsStringSync(
              '${const JsonEncoder.withIndent('  ').convert(exported)}\n',
            );
          }
        } finally {
          await journal.close();
        }
      },
    );
  }
  test(
    'R3 an imported top-level todo exits and stays a paragraph on reverse import',
    () async {
      final snapshot = _root([
        {
          ..._paragraph(),
          'flavour': 'todo',
          'props': {'checked': 1, 'depth': 0},
        },
      ]);
      final journal = await _open(snapshot);
      try {
        final state = journal.editor.editorState;
        state.selection = Selection.collapsed(Position(path: [0, 0]));
        expect(await handleDocumentParagraphEnter(state), true);
        expect(state.getNodeAtPath([0, 0])!.type, ParagraphBlockKeys.type);
        final exported = journal.exportBlockCraftSnapshot();
        expect(
          ((exported['children'] as List).single as Map)['flavour'],
          'paragraph',
        );
        final restored = await _open(exported);
        try {
          expect(
            restored.editor.editorState.getNodeAtPath([0, 0])!.type,
            ParagraphBlockKeys.type,
          );
        } finally {
          await restored.close();
        }
      } finally {
        await journal.close();
      }
    },
  );
  test(
    'R5 text, append and subtree deletion respect an imported ancestor lock',
    () async {
      final journal = await _open(_container());
      try {
        final state = journal.editor.editorState;
        final container = state.getNodeAtPath([0, 0])!;
        final child = container.children.single;
        await state.apply(state.transaction..insertText(child, 0, 'blocked'));
        expect(child.delta!.toPlainText(), isEmpty);
        await state.apply(
          state.transaction
            ..insertNode([0, 0, 1], paragraphNode(text: 'blocked')),
        );
        expect(container.children.length, 1);
        await state.apply(state.transaction..deleteNode(container));
        expect(state.getNodeAtPath([0, 0]), same(container));
      } finally {
        await journal.close();
      }
    },
  );
  test(
    'R5 inserting before a locked sibling is allowed and preserves sibling lock',
    () async {
      final journal = await _open(_container());
      try {
        final state = journal.editor.editorState;
        final container = state.getNodeAtPath([0, 0])!;
        await state.apply(
          state.transaction..insertNode([0, 0], paragraphNode(text: 'allowed')),
        );
        expect(state.getNodeAtPath([0, 0])!.delta!.toPlainText(), 'allowed');
        expect(state.getNodeAtPath([0, 1]), same(container));
        expect(
          BlockCraftJsonCodec.properties(container, metadata: true)['lock'],
          'user-demo',
        );
      } finally {
        await journal.close();
      }
    },
  );
  test(
    'R5 a prefix deletion cannot hide a shifted locked insertion target',
    () async {
      final journal = await _open(_container(prefix: true));
      try {
        final state = journal.editor.editorState;
        final prefix = state.getNodeAtPath([0, 0])!;
        final container = state.getNodeAtPath([0, 1])!;
        final transaction = state.transaction
          ..add(DeleteOperation([0, 0], [prefix]), transform: false)
          ..add(
            InsertOperation([0, 0, 1], [paragraphNode(text: 'blocked')]),
            transform: false,
          );
        await state.apply(transaction);
        expect(state.getNodeAtPath([0, 0]), same(prefix));
        expect(state.getNodeAtPath([0, 1]), same(container));
        expect(container.children.length, 1);
      } finally {
        await journal.close();
      }
    },
  );
  test(
    'R5 locking then appending in one transaction is rejected atomically',
    () async {
      final journal = await _open(_container(locked: false));
      try {
        final state = journal.editor.editorState;
        final container = state.getNodeAtPath([0, 0])!;
        final transaction = state.transaction
          ..updateNode(container, {
            'bc.m:lock': {'v': 'user-demo'},
          })
          ..add(
            InsertOperation([0, 0, 1], [paragraphNode(text: 'blocked')]),
            transform: false,
          );
        await state.apply(transaction);
        expect(container.children.length, 1);
        expect(
          BlockCraftJsonCodec.properties(container, metadata: true)['lock'],
          isNull,
        );
      } finally {
        await journal.close();
      }
    },
  );
  test(
    'R5 rejected insertion leaves source identities and detached operation nodes untouched',
    () async {
      final journal = await _open(_container());
      try {
        final state = journal.editor.editorState;
        final source = state.getNodeAtPath([0, 0, 0])!;
        final duplicate = source.copyWith();
        final before = jsonEncode(duplicate.toJson());
        final transaction = state.transaction
          ..add(InsertOperation([0, 1], [duplicate]), transform: false)
          ..add(
            InsertOperation([0, 0, 1], [paragraphNode(text: 'blocked')]),
            transform: false,
          );
        await state.apply(transaction);
        expect(state.document.root.children.single.children.length, 1);
        expect(jsonEncode(duplicate.toJson()), before);
        expect(source.attributes['bc.id'], 'paragraph');
      } finally {
        await journal.close();
      }
    },
  );
  test(
    'inserted copies receive new ids while ordinary text edits retain existing ids',
    () async {
      final journal = await _open(_root([_paragraph()]));
      try {
        final state = journal.editor.editorState;
        final original = state.getNodeAtPath([0, 0])!;
        await state.apply(
          state.transaction..insertNode([0, 1], original.copyWith()),
        );
        final exported = journal.exportBlockCraftSnapshot();
        final blocks = exported['children'] as List;
        expect(blocks.length, 2);
        expect((blocks.first as Map)['id'], 'paragraph');
        expect((blocks.last as Map)['id'], isNot('paragraph'));
        final second = state.getNodeAtPath([0, 1])!;
        final id = (blocks.last as Map)['id'];
        await state.apply(state.transaction..insertText(second, 0, 'edit'));
        expect(
          ((journal.exportBlockCraftSnapshot()['children'] as List).last
              as Map)['id'],
          id,
        );
      } finally {
        await journal.close();
      }
    },
  );
}
