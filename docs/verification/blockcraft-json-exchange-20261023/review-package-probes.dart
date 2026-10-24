import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_callout_block.dart';
import 'package:cses_document_collab/src/editor/collab_list_editing.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_entity_mention.dart';
import 'package:cses_document_collab/src/model/collab_task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 创建独立虚构块；[kind]/[type]为桌面类型，[props]/[meta]/[children]为实际字段。
Map<String, dynamic> _block(
  String kind,
  String type, {
  Map<String, dynamic> props = const {},
  Map<String, dynamic> meta = const {},
  List<Object> children = const [],
}) => {'id': kind, 'flavour': kind, 'nodeType': type, 'props': props, 'meta': meta, 'children': children};

/// 为独立[block]创建使用正式完整文档能力的本地编辑器；调用者负责关闭。
DocumentEditorController _editor(Map<String, dynamic> block) => DocumentEditorController(
  document: BlockCraftJsonCodec.decode(_block('root', 'root', children: [block])),
  commandContext: const EditorCommandContext(localOnly: true, configuration: EditorConfiguration.document),
);

/// 以正确行为作为断言，记录提交189ffad的数据与渲染反例；不修改生产实现。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('R1 block conversion preserves imported identity, metadata and business fields', () async {
    final editor = _editor(
      _block(
        'paragraph',
        'editable',
        meta: {'audit': 'demo'},
        props: {'depth': 0, 'custom': 'demo'},
        children: [
          {'insert': '业务内容'},
        ],
      ),
    );
    try {
      final state = editor.editorState;
      state.document.first!.updateAttributes({
        'guidance_entry': 'help',
        'guidance_entry_id': 'entry-demo',
        'guidance_done': true,
      });
      state.selection = Selection.single(path: [0], startOffset: 0, endOffset: 2);
      await applyEditorBlockStyle(state, HeadingBlockKeys.type, headingLevel: 2);
      final node = state.document.first!;
      debugPrint(
        'R1 ${jsonEncode({'type': node.type, 'business': node.attributes['guidance_entry'], 'bc.id': node.attributes['bc.id'], 'meta': BlockCraftJsonCodec.encodeBlock(node)['meta']})}',
      );
      expect(node.type, HeadingBlockKeys.type);
      expect(node.attributes['guidance_entry_id'], 'entry-demo');
      expect(node.attributes['bc.id'], 'paragraph');
    } finally {
      await editor.close();
    }
  });

  test('R2 callout appearance edits are exported from current state', () async {
    final editor = _editor(
      _block(
        'callout',
        'block',
        props: {'prefix': '旧', 'backColor': '#ffe6cd'},
        children: [
          _block(
            'paragraph',
            'editable',
            children: [
              {'insert': '内容'},
            ],
          ),
        ],
      ),
    );
    try {
      await updateCollabCalloutAppearance(editor.editorState, 'callout', csesBlockBackgroundColorAttribute, '#112233');
      await updateCollabCalloutAppearance(editor.editorState, 'callout', csesCalloutPrefixAttribute, '新');
      final node = editor.editorState.document.first!;
      final encoded = BlockCraftJsonCodec.encodeBlock(node);
      debugPrint(
        'R2 ${jsonEncode({'nativeColor': node.attributes[csesBlockBackgroundColorAttribute], 'nativePrefix': node.attributes[csesCalloutPrefixAttribute], 'exportedProps': encoded['props']})}',
      );
      expect(node.attributes[csesBlockBackgroundColorAttribute], '#112233');
      expect((encoded['props'] as Map)['backColor'], '#112233');
      expect((encoded['props'] as Map)['prefix'], '新');
    } finally {
      await editor.close();
    }
  });

  test('R3 exiting an imported todo exports a paragraph', () async {
    final editor = _editor(_block('todo', 'editable', props: {'checked': 1, 'depth': 0}));
    try {
      final state = editor.editorState;
      state.selection = Selection.collapsed(Position(path: [0]));
      expect(await outdentCollabListAtStart(state), isTrue);
      final node = state.document.first!;
      final encoded = BlockCraftJsonCodec.encodeBlock(node);
      debugPrint(
        'R3 ${jsonEncode({'nativeType': node.type, 'exportedFlavour': encoded['flavour'], 'props': encoded['props']})}',
      );
      expect(node.type, ParagraphBlockKeys.type);
      expect(encoded['flavour'], 'paragraph');
    } finally {
      await editor.close();
    }
  });

  test('R6 a newly converted task card exports its actual task reference', () async {
    final editor = _editor(
      _block(
        'paragraph',
        'editable',
        children: [
          {
            'insert': {'mention': '任务探针'},
            'attributes': {'mentionId': 'task-demo', 'mentionType': 'task'},
          },
        ],
      ),
    );
    try {
      final state = editor.editorState;
      final target = CollabEntityMentionTarget.capture(state.document.first!, 0)!;
      expect(await convertCollabEntityMentionToCard(state, target), isTrue);
      final card = state.document.root.children.singleWhere((node) => node.type == 'task');
      final encoded = BlockCraftJsonCodec.encodeBlock(card);
      debugPrint(
        'R6 ${jsonEncode({'nativeResource': CollabTaskCard.read(card.attributes).values, 'exportedProps': encoded['props']})}',
      );
      expect(CollabTaskCard.read(card.attributes).values['taskId'], 'task-demo');
      expect((encoded['props'] as Map)['taskId'], 'task-demo');
    } finally {
      await editor.close();
    }
  });

  testWidgets('R4 explicit font weight retains the native mention widget', (tester) async {
    final editor = _editor(
      _block(
        'paragraph',
        'editable',
        children: [
          {
            'insert': {'mention': '探针人员'},
            'attributes': {'mentionId': 'u-demo', 'mentionType': 'user'},
          },
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DocumentEditorView(editorState: editor.editorState)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('探针人员', findRichText: true), findsWidgets);
    final state = editor.editorState;
    final node = state.document.first!;
    await state.apply(state.transaction..formatText(node, 0, 1, {'bc.a:s:fontWeight': '600'}));
    await tester.pumpAndSettle();
    debugPrint('R4 visibleMentions=${find.textContaining('探针人员', findRichText: true).evaluate().length}');
    final count = find.textContaining('探针人员', findRichText: true).evaluate().length;
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(editor.close);
    expect(count, greaterThan(0));
  });
}
