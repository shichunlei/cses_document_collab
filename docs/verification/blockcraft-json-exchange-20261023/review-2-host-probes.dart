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

/// 复查连续编辑的完整性；失败断言表示可复现的数据丢失。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'empty heading Enter preserves business metadata and stable identity',
    () async {
      final journal = await _open(
        _root([
          {
            ..._paragraph(
              meta: {
                'audit': 'demo',
                'mobileGuidance': {
                  'version': 1,
                  'role': 'content',
                  'section': 'record',
                  'business': {
                    'guidance_entry': 'help',
                    'guidance_entry_id': 'entry-demo',
                    'guidance_done': false,
                  },
                },
              },
            ),
            'props': {'heading': 2},
          },
        ]),
      );
      try {
        final state = journal.editor.editorState;
        state.selection = Selection.collapsed(Position(path: [0, 0]));
        expect(await handleDocumentParagraphEnter(state), true);
        expect(state.getNodeAtPath([0, 0])!.type, ParagraphBlockKeys.type);
        final output =
            (journal.exportBlockCraftSnapshot()['children'] as List).single
                as Map;
        // 首先验证可见转换确实执行，再断言元数据没有被编辑命令删除。
        File(
          'docs/verification/blockcraft-json-exchange-20261023/review-2-heading-enter.json',
        ).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            'currentNode': state.getNodeAtPath([0, 0])!.toJson(),
            'exportedBlock': output,
          }),
        );
        expect(
          ((output['meta'] as Map)['mobileGuidance'] as Map)['business'],
          containsPair('guidance_entry_id', 'entry-demo'),
        );
        expect(output['meta'], containsPair('audit', 'demo'));
        expect(output['id'], 'paragraph');
      } finally {
        await journal.close();
      }
    },
  );
  test(
    'todo hardware indentation preserves the selected block in JSON',
    () async {
      final journal = await _open(
        _root([
          {
            ..._paragraph(id: 'first'),
            'children': [
              {'insert': 'anchor'},
            ],
          },
          {
            ..._paragraph(id: 'second'),
            'children': [
              {'insert': 'body'},
            ],
          },
          {
            ..._paragraph(id: 'third'),
            'flavour': 'todo',
            'props': {'checked': 1},
            'children': [
              {'insert': 'todo'},
            ],
          },
        ]),
      );
      try {
        final state = journal.editor.editorState;
        state.selection = Selection.collapsed(
          Position(path: [0, 2], offset: 4),
        );
        indentCommand.execute(state);
        await pumpEventQueue();
        expect(
          journal.editor.commandContext.configuration.structuralIndentation,
          true,
        );
        final nested = state.getNodeAtPath([0, 1, 0])!;
        expect(nested.type, TodoListBlockKeys.type);
        expect(nested.attributes['checked'], true);
        final exported = journal.exportBlockCraftSnapshot();
        File(
          'docs/verification/blockcraft-json-exchange-20261023/review-2-todo-tab.json',
        ).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            'currentSection': state.getNodeAtPath([0])!.toJson(),
            'exported': exported,
          }),
        );
        final output = jsonEncode(exported);
        expect(output, contains('body'));
        expect(output, contains('todo'));
      } finally {
        await journal.close();
      }
    },
  );
  test(
    'duplicated imported container retains fresh identities across undo redo',
    () async {
      final journal = await _open(_container(locked: false));
      try {
        final state = journal.editor.editorState;
        final container = state.getNodeAtPath([0, 0])!;
        await state.apply(
          state.transaction..insertNode([0, 1], container.copyWith()),
          skipHistoryDebounce: true,
        );
        expect(state.getNodeAtPath([0])!.children.length, 2);
        final output = journal.exportBlockCraftSnapshot();
        state.undoManager.undo();
        await pumpEventQueue();
        expect(state.getNodeAtPath([0])!.children.length, 1);
        state.undoManager.redo();
        await pumpEventQueue();
        expect(
          journal.exportBlockCraftSnapshot()['children'],
          output['children'],
        );
      } finally {
        await journal.close();
      }
    },
  );
}
