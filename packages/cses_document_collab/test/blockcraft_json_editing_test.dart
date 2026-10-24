import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_callout_block.dart';
import 'package:cses_document_collab/src/editor/collab_inline_entity_mention.dart';
import 'package:cses_document_collab/src/editor/collab_inline_formula.dart';
import 'package:cses_document_collab/src/editor/collab_inline_mention.dart';
import 'package:cses_document_collab/src/editor/collab_list_editing.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_entity_mention.dart';
import 'package:cses_document_collab/src/model/collab_task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 创建虚构独立块；[kind]/[type]为桌面类型，[props]/[meta]/[children]为真实协议字段。
Map<String, dynamic> _block(
  String kind,
  String type, {
  Map<String, dynamic> props = const {},
  Map<String, dynamic> meta = const {},
  List<Object> children = const [],
}) => {'id': kind, 'flavour': kind, 'nodeType': type, 'props': props, 'meta': meta, 'children': children};

/// 使用完整文档能力和显式业务字段保留合同打开[block]；调用方负责关闭。
DocumentEditorController _editor(Map<String, dynamic> block) => DocumentEditorController(
  document: BlockCraftJsonCodec.decode(_block('root', 'root', children: [block])),
  commandContext: EditorCommandContext(
    localOnly: true,
    configuration: EditorConfiguration.document.withHost(
      preservedAttributes: const {'guidance_entry', 'guidance_entry_id', 'guidance_done'},
    ),
  ),
);

/// 将借用的[node]导出、反向转换、落盘恢复后再导出，验证真实当前树及独立字段。
Map<String, dynamic> _roundTrip(Node node) {
  final document = BlockCraftJsonCodec.decode(
    _block('root', 'root', children: [BlockCraftJsonCodec.encodeBlock(node)]),
  );
  final restored = Document.fromJson(jsonDecode(jsonEncode(document.toJson())) as Map<String, dynamic>);
  try {
    return Map<String, dynamic>.from((BlockCraftJsonCodec.encode(restored)['children'] as List).single as Map);
  } finally {
    document.dispose();
    restored.dispose();
  }
}

/// 验证六项审查缺陷的编辑、撤销、再次导入和真实原子渲染，不依赖原生协同文档。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('host configuration copies contracts without changing document capabilities', () {
    final fields = ['entry'];
    final containers = ['host'];
    final config = EditorConfiguration.document.withHost(
      preservedAttributes: fields,
      listContainers: containers,
      listIndentContainers: containers,
    );
    fields.clear();
    containers.clear();
    expect(config.documentFeatures, true);
    expect(config.blockConversionPreservedAttributes, {'entry'});
    expect(config.listConversionContainerTypes, {'host'});
    expect(config.listIndentContainerTypes, {'host'});
    expect(config.allowsTextAttributes({'custom': 'value'}), true);
    expect(config.allowsTextAttributes({'t:px': 23}), EditorConfiguration.document.allowsTextAttributes({'t:px': 23}));
    expect(EditorConfiguration.document.blockConversionPreservedAttributes, isEmpty);
    expect(() => config.blockConversionPreservedAttributes.add('other'), throwsUnsupportedError);
    expect(() => config.withHost(preservedAttributes: [' ']), throwsArgumentError);
  });
  test('R1 converting imported content preserves identity, metadata and custom properties through undo', () async {
    final editor = _editor(
      _block(
        'paragraph',
        'editable',
        meta: {'audit': 'demo'},
        props: {'depth': 0, 'custom': null},
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
      expect(node.type, HeadingBlockKeys.type);
      expect(node.attributes['guidance_entry_id'], 'entry-demo');
      final encoded = _roundTrip(node);
      expect(encoded['id'], 'paragraph');
      expect(encoded['meta'], {'audit': 'demo'});
      expect((encoded['props'] as Map)['heading'], 2);
      expect((encoded['props'] as Map).containsKey('custom'), true);
      state.undoManager.undo();
      await pumpEventQueue();
      expect(state.document.first!.type, ParagraphBlockKeys.type);
      state.undoManager.redo();
      await pumpEventQueue();
      expect(_roundTrip(state.document.first!)['id'], 'paragraph');
      expect(state.document.first!.attributes['guidance_entry_id'], 'entry-demo');
    } finally {
      await editor.close();
    }
  });
  test('R1 live code, quote and list types override imported flavour while retaining identity', () async {
    final editor = _editor(
      _block(
        'paragraph',
        'editable',
        children: [
          {'insert': 'text'},
        ],
      ),
    );
    try {
      final state = editor.editorState;
      for (final entry in {
        'code': 'code',
        'paragraph': 'paragraph',
        'quote': 'blockquote',
        'todo_list': 'todo',
        'numbered_list': 'ordered',
        'bulleted_list': 'bullet',
      }.entries) {
        state.selection = Selection.single(path: [0], startOffset: 0, endOffset: 4);
        await applyEditorBlockStyle(state, entry.key);
        expect(state.document.first!.type, entry.key);
        final encoded = _roundTrip(state.document.first!);
        expect(encoded['flavour'], entry.value);
        expect(encoded['id'], 'paragraph');
      }
    } finally {
      await editor.close();
    }
  });

  test('R2 all callout appearance values and clears survive reverse conversion and undo', () async {
    final editor = _editor(
      _block(
        'callout',
        'block',
        props: {'prefix': '旧', 'backColor': '#ffe6cd', 'custom': 'keep'},
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
    const fields = {
      'prefix': csesCalloutPrefixAttribute,
      'color': csesBlockTextColorAttribute,
      'backColor': csesBlockBackgroundColorAttribute,
      'borderColor': csesBlockBorderColorAttribute,
    };
    try {
      for (final entry in fields.entries) {
        final value = entry.key == 'prefix' ? '新' : '#112233';
        await updateCollabCalloutAppearance(editor.editorState, 'callout', entry.value, value);
        expect((_roundTrip(editor.editorState.document.first!)['props'] as Map)[entry.key], value);
      }
      for (final entry in fields.entries) {
        await updateCollabCalloutAppearance(editor.editorState, 'callout', entry.value, null);
        expect((_roundTrip(editor.editorState.document.first!)['props'] as Map).containsKey(entry.key), false);
      }
      expect((_roundTrip(editor.editorState.document.first!)['props'] as Map)['custom'], 'keep');
      editor.editorState.undoManager.undo();
      await pumpEventQueue();
      expect((_roundTrip(editor.editorState.document.first!)['props'] as Map)['borderColor'], '#112233');
      editor.editorState.undoManager.redo();
      await pumpEventQueue();
      expect((_roundTrip(editor.editorState.document.first!)['props'] as Map).containsKey('borderColor'), false);
    } finally {
      await editor.close();
    }
  });
  for (final kind in ['todo', 'bullet', 'ordered']) {
    test('R3 exiting $kind exports a paragraph and undo restores its original type', () async {
      final editor = _editor(
        _block(
          kind,
          'editable',
          props: {'depth': 0, if (kind == 'todo') 'checked': 1, if (kind == 'ordered') 'start': 7},
        ),
      );
      try {
        final state = editor.editorState;
        state.selection = Selection.collapsed(Position(path: [0]));
        expect(await outdentCollabListAtStart(state), true);
        expect(state.document.first!.type, ParagraphBlockKeys.type);
        final encoded = _roundTrip(state.document.first!);
        expect(encoded['flavour'], 'paragraph');
        expect(encoded['id'], kind);
        expect((encoded['props'] as Map).containsKey('checked'), false);
        expect((encoded['props'] as Map).containsKey('start'), false);
        state.undoManager.undo();
        await pumpEventQueue();
        expect(_roundTrip(state.document.first!)['flavour'], kind);
        state.undoManager.redo();
        await pumpEventQueue();
        expect(_roundTrip(state.document.first!)['flavour'], 'paragraph');
      } finally {
        await editor.close();
      }
    });
  }
  test('explicit body conversion removes the special word-art text role', () async {
    final editor = _editor(
      _block(
        'word-art',
        'editable',
        children: [
          {'insert': '艺术字'},
        ],
      ),
    );
    try {
      final state = editor.editorState;
      expect(_roundTrip(state.document.first!)['flavour'], 'word-art');
      state.selection = Selection.single(path: [0], startOffset: 0, endOffset: 3);
      await applyEditorBlockStyle(state, ParagraphBlockKeys.type);
      expect(_roundTrip(state.document.first!)['flavour'], 'paragraph');
    } finally {
      await editor.close();
    }
  });
  test('R6 a newly converted task card keeps its reference across both JSON directions and undo', () async {
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
      expect(await convertCollabEntityMentionToCard(state, target), true);
      final card = state.document.root.children.singleWhere((node) => node.type == 'task');
      expect(CollabTaskCard.read(card.attributes).values['taskId'], 'task-demo');
      expect(_roundTrip(card)['props'], {'taskId': 'task-demo', 'title': '任务探针'});
      if (const bool.fromEnvironment('GENERATE_BLOCKCRAFT_EXAMPLES')) {
        final snapshot = BlockCraftJsonCodec.encode(state.document);
        File(
          '../../docs/verification/blockcraft-json-exchange-20261023/fixed-task-card.json',
        ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(snapshot)}\n');
      }
      state.undoManager.undo();
      await pumpEventQueue();
      expect(state.document.root.children.where((node) => node.type == 'task'), isEmpty);
      state.undoManager.redo();
      await pumpEventQueue();
      expect(
        (_roundTrip(state.document.root.children.singleWhere((node) => node.type == 'task'))['props'] as Map)['taskId'],
        'task-demo',
      );
    } finally {
      await editor.close();
    }
  });
  for (final flavour in ['paragraph', 'word-art']) {
    for (final kind in ['user', 'meeting', 'task', 'doc', 'latex']) {
      testWidgets('R4 $flavour $kind remains a styled native atom after explicit font weight', (tester) async {
        final editor = _editor(
          _block(
            flavour,
            'editable',
            children: [
              {
                'insert': kind == 'latex' ? {'latex': 'x^2'} : {'mention': '探针人员'},
                if (kind != 'latex') 'attributes': {'mentionId': 'id-demo', 'mentionType': kind},
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
        final state = editor.editorState;
        final node = state.document.first!;
        await state.apply(state.transaction..formatText(node, 0, 1, {'bc.a:s:fontWeight': '600', 'italic': true}));
        await tester.pumpAndSettle();
        final TextStyle style;
        if (kind == 'latex') {
          style = tester.widget<CollabInlineFormula>(find.byType(CollabInlineFormula)).style;
        } else if (kind == 'user') {
          style = tester.widget<CollabInlineMention>(find.byType(CollabInlineMention)).style;
        } else {
          style = tester.widget<CollabInlineEntityMention>(find.byType(CollabInlineEntityMention)).style;
        }
        expect(style.fontWeight, FontWeight.w600);
        expect(style.fontStyle, FontStyle.italic);
        if (kind != 'latex') expect(find.textContaining('探针人员', findRichText: true), findsWidgets);
        expect((((_roundTrip(node)['children'] as List).single as Map)['attributes'] as Map)['s:fontWeight'], '600');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        await tester.runAsync(editor.close);
      });
    }
  }
}
