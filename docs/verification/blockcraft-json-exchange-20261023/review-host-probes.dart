import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_blockcraft_codec.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_store.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// 持有独立虚构[draft]的内存存储，不访问用户数据。
class _Store implements JournalStore {
  /// [draft]为此存储的独立初值。
  _Store(this.draft);

  /// 此探针独占的恢复值。
  JournalDraft draft;

  /// 返回独立生产模型副本。
  @override
  Future<JournalDraft?> read() async => JournalDraft.fromJson(draft.toJson());

  /// 保存独立[value]，不操作平台文件。
  @override
  Future<void> write(JournalDraft value) async =>
      draft = JournalDraft.fromJson(value.toJson());
}

/// 将虚构[children]包装为已注册的独立桌面根块。
Map<String, dynamic> _root(List<Map<String, dynamic>> children) => {
  'id': 'root',
  'flavour': 'root',
  'nodeType': 'root',
  'props': <String, Object>{},
  'meta': <String, Object>{},
  'children': children,
};

/// 创建虚构空正文，按[meta]提供已转换的业务或锁元数据。
Map<String, dynamic> _paragraph({Map<String, dynamic> meta = const {}}) => {
  'id': 'paragraph',
  'flavour': 'paragraph',
  'nodeType': 'editable',
  'props': <String, Object>{},
  'meta': meta,
  'children': <Object>[],
};

/// 对实际宿主控制器的类型转换与锁保护建立正确行为断言；不修改生产逻辑。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'R1 actual imported journal retains business identity through public heading conversion',
    () async {
      final snapshot = _root([
        _paragraph(
          meta: {
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
      ]);
      final journal = await LocalJournalController.open(
        store: _Store(JournalBlockCraftCodec.importSnapshot(snapshot)),
      );
      try {
        final state = journal.editor.editorState;
        final selection = Selection.collapsed(Position(path: [0, 0]));
        state.selection = selection;
        expect(
          state.getNodeAtPath([0, 0])!.attributes['guidance_entry_id'],
          'entry-demo',
        );
        expect(
          await applyDocumentBlockShortcut(
            state,
            selection,
            HeadingBlockKeys.type,
            headingLevel: 2,
          ),
          isTrue,
        );
        final node = state.getNodeAtPath([0, 0])!;
        final exported = journal.exportBlockCraftSnapshot();
        debugPrint(
          'HOST R1 ${jsonEncode({'type': node.type, 'entryId': node.attributes['guidance_entry_id'], 'exported': exported['children']})}',
        );
        expect(node.type, HeadingBlockKeys.type);
        expect(node.attributes['guidance_entry_id'], 'entry-demo');
      } finally {
        await journal.close();
      }
    },
  );
  test(
    'R5 appending into a locked imported container must be rejected',
    () async {
      final snapshot = _root([
        {
          'id': 'callout',
          'flavour': 'callout',
          'nodeType': 'block',
          'props': <String, Object>{},
          'meta': {'lock': 'user-demo'},
          'children': [_paragraph()],
        },
      ]);
      final journal = await LocalJournalController.open(
        store: _Store(JournalBlockCraftCodec.importSnapshot(snapshot)),
      );
      try {
        final state = journal.editor.editorState;
        final container = state.getNodeAtPath([0, 0])!;
        final child = container.children.single;
        await state.apply(state.transaction..insertText(child, 0, 'blocked'));
        expect(child.delta!.toPlainText(), isEmpty);
        await state.apply(
          state.transaction..insertNode([0, 0, 1], paragraphNode(text: '越锁写入')),
        );
        debugPrint(
          'HOST R5 lockedContainerChildren=${container.children.length}',
        );
        expect(container.children.length, 1);
      } finally {
        await journal.close();
      }
    },
  );
}
