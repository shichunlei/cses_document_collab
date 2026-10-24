import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_indent.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 创建虚构桌面块；[id]稳定且唯一，[kind]为flavour，[props]/[meta]/[children]为协议字段。
Map<String, dynamic> _block(
  String id,
  String kind, {
  Map<String, dynamic> props = const {},
  Map<String, dynamic> meta = const {},
  List<Object> children = const [],
}) => {
  'id': id,
  'flavour': kind,
  'nodeType': kind == 'root' ? 'root' : 'editable',
  'props': props,
  'meta': meta,
  'children': children,
};

/// 打开虚构[block]并配置额外业务字段；返回会话由调用方关闭。
DocumentEditorController _open(Map<String, dynamic> block) => DocumentEditorController(
  document: BlockCraftJsonCodec.decode(_block('root', 'root', children: [block])),
  commandContext: EditorCommandContext(
    localOnly: true,
    configuration: EditorConfiguration.document.withHost(preservedAttributes: {'entry', 'done'}),
  ),
);

/// 对借用[state]执行桌面反向转换和本地JSON恢复，断言完整导出结果相等。
Map<String, dynamic> _roundTrip(EditorState state) {
  final snapshot = BlockCraftJsonCodec.encode(state.document);
  final imported = BlockCraftJsonCodec.decode(jsonDecode(jsonEncode(snapshot)) as Map<String, dynamic>);
  final restored = Document.fromJson(jsonDecode(jsonEncode(imported.toJson())) as Map<String, dynamic>);
  try {
    expect(BlockCraftJsonCodec.encode(restored), snapshot);
    return snapshot;
  } finally {
    imported.dispose();
    restored.dispose();
  }
}

/// 验证真实Tab、空标题/引用回车与非法嵌套边界，不连接业务或原生文档。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('host may disable native structural commands without changing document defaults', () {
    final config = EditorConfiguration.document.withHost(structuralIndentation: false);
    expect(config.structuralIndentation, false);
    expect(config.withHost().structuralIndentation, false);
    expect(EditorConfiguration.document.structuralIndentation, true);
    expect(config.documentFeatures, true);
  });
  for (final kind in ['todo', 'bullet', 'ordered']) {
    test('$kind Tab and Shift Tab keep a flat tree, text, state and identities through history and JSON', () async {
      final editor = _open(
        _block(
          'item',
          kind,
          props: {'checked': 1},
          meta: {'audit': 'demo'},
          children: [
            {
              'insert': '格式',
              'attributes': {'a:bold': true, 't:px': 22},
            },
            {
              'insert': {'mention': '测试人员'},
              'attributes': {'mentionId': 'user-demo', 'mentionType': 'user'},
            },
          ],
        ),
      );
      try {
        final state = editor.editorState;
        state.selection = Selection.collapsed(Position(path: [0], offset: 1));
        final before = _roundTrip(state);
        expect(collabParagraphTabCommand.execute(state), KeyEventResult.handled);
        await pumpEventQueue();
        expect(state.document.first!.children, isEmpty);
        expect(state.document.root.children, hasLength(1));
        final after = _roundTrip(state);
        final block = (after['children'] as List).single as Map;
        expect(block['id'], 'item');
        expect(block['meta'], {'audit': 'demo'});
        expect((block['props'] as Map)['depth'], 1);
        if (kind == 'todo') expect((block['props'] as Map)['checked'], 1);
        expect(block['children'], ((before['children'] as List).single as Map)['children']);
        state.undoManager.undo();
        await pumpEventQueue();
        expect(_roundTrip(state), before);
        state.undoManager.redo();
        await pumpEventQueue();
        expect(_roundTrip(state), after);
        expect(collabParagraphShiftTabCommand.execute(state), KeyEventResult.handled);
        await pumpEventQueue();
        expect(
          state.document.first!.type,
          kind == 'todo'
              ? 'todo_list'
              : kind == 'bullet'
              ? 'bulleted_list'
              : 'numbered_list',
        );
        expect(((_roundTrip(state)['children'] as List).single as Map)['props'], containsPair('depth', 0));
      } finally {
        await editor.close();
      }
    });
    test('$kind Tab at maximum consumes the event; readonly does not mutate', () async {
      final editor = _open(
        _block(
          'item',
          kind,
          props: {'depth': 6, 'checked': 1},
          children: [
            {'insert': 'text'},
          ],
        ),
      );
      try {
        final state = editor.editorState;
        state.selection = Selection.collapsed(Position(path: [0]));
        final before = _roundTrip(state);
        expect(collabParagraphTabCommand.execute(state), KeyEventResult.handled);
        await pumpEventQueue();
        expect(_roundTrip(state), before);
        state.editable = false;
        expect(collabParagraphShiftTabCommand.execute(state), KeyEventResult.ignored);
        expect(_roundTrip(state), before);
      } finally {
        await editor.close();
      }
    });
  }
  test('codec rejects real descendants under text leaves without modifying the tree', () async {
    final editor = _open(
      _block(
        'item',
        'todo',
        props: {'checked': 1},
        children: [
          {'insert': 'outer'},
        ],
      ),
    );
    try {
      final state = editor.editorState;
      await state.apply(state.transaction..insertNode([0, 0], paragraphNode(text: 'must survive')));
      final before = jsonEncode(state.document.toJson());
      expect(() => BlockCraftJsonCodec.encodeBlock(state.document.first!), throwsFormatException);
      expect(() => BlockCraftJsonCodec.encode(state.document), throwsFormatException);
      expect(jsonEncode(state.document.toJson()), before);
      expect(state.document.first!.children.single.delta!.toPlainText(), 'must survive');
    } finally {
      await editor.close();
    }
  });
  for (final variant in ['heading', 'quote-body', 'quote-same']) {
    test('empty $variant Enter retains business, metadata and identity across history and JSON', () async {
      final editor = _open(
        _block(
          'item',
          variant == 'heading' ? 'paragraph' : 'blockquote',
          props: {
            if (variant == 'heading') 'heading': 2,
            'nextParagraphStyle': variant == 'quote-same' ? 'same' : 'body',
            'fs': 28,
            'custom': null,
          },
          meta: {'audit': 'demo'},
        ),
      );
      try {
        final state = editor.editorState;
        state.document.first!.updateAttributes({'entry': 'entry-demo', 'done': true});
        state.selection = Selection.collapsed(Position(path: [0]));
        final before = _roundTrip(state);
        expect(await handleDocumentParagraphEnter(state), true);
        expect(state.document.first!.type, ParagraphBlockKeys.type);
        expect(state.document.first!.attributes['entry'], 'entry-demo');
        expect(state.document.first!.attributes['done'], true);
        final after = _roundTrip(state);
        final block = (after['children'] as List).single as Map;
        expect(block['id'], 'item');
        expect(block['meta'], {'audit': 'demo'});
        expect((block['props'] as Map).containsKey('custom'), true);
        expect((block['props'] as Map)['fs'], variant == 'quote-same' ? 28 : null);
        state.undoManager.undo();
        await pumpEventQueue();
        expect(_roundTrip(state), before);
        expect(state.document.first!.attributes['entry'], 'entry-demo');
        state.undoManager.redo();
        await pumpEventQueue();
        expect(_roundTrip(state), after);
        expect(state.document.first!.attributes['entry'], 'entry-demo');
      } finally {
        await editor.close();
      }
    });
  }
  test('nonempty heading Enter creates a new body instead of reusing source identity and business', () async {
    final editor = _open(
      _block(
        'heading',
        'paragraph',
        props: {'heading': 2},
        meta: {'audit': 'demo'},
        children: [
          {'insert': 'text'},
        ],
      ),
    );
    try {
      final state = editor.editorState;
      state.document.first!.updateAttributes({'entry': 'entry-demo'});
      state.selection = Selection.collapsed(Position(path: [0], offset: 4));
      expect(await handleDocumentParagraphEnter(state), true);
      expect(state.document.root.children, hasLength(2));
      expect(state.document.first!.attributes['entry'], 'entry-demo');
      expect(state.document.last!.attributes['entry'], isNull);
      final blocks = _roundTrip(state)['children'] as List;
      expect((blocks.last as Map)['id'], isNot('heading'));
      expect((blocks.last as Map)['meta'], isEmpty);
    } finally {
      await editor.close();
    }
  });
  test('Tab inside a table keeps the navigation command available', () {
    final state = EditorState(
      document: Document(
        root: Node(
          type: 'page',
          children: [
            Node(type: 'table-cell', children: [todoListNode(checked: true)]),
          ],
        ),
      ),
    );
    try {
      state.selection = Selection.collapsed(Position(path: [0, 0]));
      expect(collabParagraphTabCommand.execute(state), KeyEventResult.ignored);
    } finally {
      state.dispose();
    }
  });
}
