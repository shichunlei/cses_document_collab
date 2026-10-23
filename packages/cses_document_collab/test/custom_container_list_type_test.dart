import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_list_editing.dart';
import 'package:cses_document_collab/src/model/collab_ordered.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证显式结构容器中的列表类型转换，不扩大其他列表命令或跨父范围。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const types = [BulletedListBlockKeys.type, NumberedListBlockKeys.type, TodoListBlockKeys.type];

  test('container configuration is copied frozen and rejects empty type names', () {
    final containers = <String>['custom-section', 'custom-section'];
    final configuration = EditorConfiguration(listConversionContainerTypes: containers);
    containers.clear();
    expect(configuration.listConversionContainerTypes, {'custom-section'});
    expect(() => configuration.listConversionContainerTypes.add('other'), throwsUnsupportedError);
    expect(EditorConfiguration().listConversionContainerTypes, isEmpty);
    expect(EditorConfiguration.document.listConversionContainerTypes, isEmpty);
    for (final invalid in ['', ' ', '\t\n']) {
      expect(() => EditorConfiguration(listConversionContainerTypes: [invalid]), throwsArgumentError);
    }
  });

  for (final source in types) {
    for (final target in types.where((type) => type != source)) {
      test('configured custom container converts $source to $target atomically', () async {
        final editor = _editor([
          _section([_list(source), paragraphNode(text: '相邻正文')]),
        ]);
        addTearDown(editor.close);
        final state = editor.editorState;
        final selection = Selection.single(path: [0, 0], startOffset: 2);
        state.selection = selection;
        final original = jsonEncode(state.document.toJson());
        final sourceDelta = Delta.fromJson(state.getNodeAtPath([0, 0])!.delta!.toJson());
        expect(await changeCollabListType(state, target), isTrue);
        final node = state.getNodeAtPath([0, 0])!;
        expect(node.type, target);
        expect(node.delta, sourceDelta);
        expect(EditorUserMention.read(node.delta!.slice(1, 2).first.attributes!).id, 'u1');
        expect(node.attributes[csesBlockIndentAttribute], 2);
        expect(node.attributes[blockComponentAlign], 'right');
        expect(node.attributes[TodoListBlockKeys.checked], target == TodoListBlockKeys.type ? false : null);
        expect(node.attributes[csesOrderedAttribute], isNull);
        expect(node.attributes[csesOrderedNumberingAttribute], isNull);
        expect(state.getNodeAtPath([0, 1])!.delta!.toPlainText(), '相邻正文');
        expect(state.selection, selection);
        state.undoManager.undo();
        expect(jsonEncode(state.document.toJson()), original);
        expect(state.selection, selection);
        expect(state.undoManager.undoStack.isEmpty, isTrue);
        state.undoManager.redo();
        expect(state.getNodeAtPath([0, 0])!.type, target);
        expect(state.getNodeAtPath([0, 0])!.delta, sourceDelta);
        expect(state.selection, selection);
      });
    }
  }

  for (final reverse in [false, true]) {
    test('same parent multi-item conversions preserve reverse=$reverse range and three history steps', () async {
      final editor = _editor([
        _section([for (final type in types) _list(type)]),
      ]);
      addTearDown(editor.close);
      final state = editor.editorState;
      final selection = Selection(
        start: Position(path: [0, reverse ? 2 : 0], offset: reverse ? 4 : 1),
        end: Position(path: [0, reverse ? 0 : 2], offset: reverse ? 1 : 4),
      );
      state.selection = selection;
      state.selectionType = SelectionType.block;
      final original = jsonEncode(state.document.toJson());
      final deltas = [for (final node in state.document.root.children.single.children) node.delta!.toJson()];
      for (final target in [NumberedListBlockKeys.type, TodoListBlockKeys.type, BulletedListBlockKeys.type]) {
        expect(await changeCollabListType(state, target), isTrue);
        final nodes = state.document.root.children.single.children;
        expect(nodes.map((node) => node.type), everyElement(target));
        expect(nodes.map((node) => node.delta!.toJson()), deltas);
        expect(state.selection, selection);
        expect(state.selectionType, SelectionType.block);
      }
      for (var i = 0; i < 3; i++) {
        state.undoManager.undo();
        expect(state.selection, selection);
      }
      expect(jsonEncode(state.document.toJson()), original);
      expect(state.undoManager.undoStack.isEmpty, isTrue);
      for (var i = 0; i < 3; i++) {
        state.undoManager.redo();
        expect(state.selection, selection);
      }
      expect(
        state.document.root.children.single.children.map((node) => node.type),
        everyElement(BulletedListBlockKeys.type),
      );
      expect(state.undoManager.redoStack.isEmpty, isTrue);
    });
  }

  test('unconfigured containers and cross-container selections reject the entire conversion', () async {
    for (final configured in [false, true]) {
      final editor = _editor([
        _section([_list(BulletedListBlockKeys.type)]),
        _section([_list(TodoListBlockKeys.type)]),
      ], containers: configured ? const ['custom-section'] : const []);
      final state = editor.editorState;
      state.selection = configured
          ? Selection(
              start: Position(path: [0, 0], offset: 0),
              end: Position(path: [1, 0], offset: 3),
            )
          : Selection.single(path: [0, 0], startOffset: 0);
      final before = jsonEncode(state.document.toJson());
      expect(await changeCollabListType(state, NumberedListBlockKeys.type), isFalse);
      expect(jsonEncode(state.document.toJson()), before);
      expect(state.undoManager.undoStack.isEmpty, isTrue);
      await editor.close();
    }
  });

  test('configured names never authorize text parents or genuinely nested list nodes', () async {
    for (final nestedLeaf in [false, true]) {
      final editor = _editor([
        nestedLeaf
            ? _section([
                _list(BulletedListBlockKeys.type, children: [_list(TodoListBlockKeys.type)]),
              ])
            : Node(
                type: 'custom-section',
                attributes: {blockComponentDelta: (Delta()..insert('父正文')).toJson()},
                children: [_list(BulletedListBlockKeys.type)],
              ),
      ]);
      final state = editor.editorState;
      state.selection = Selection.single(path: [0, 0], startOffset: 0);
      final before = jsonEncode(state.document.toJson());
      expect(await changeCollabListType(state, NumberedListBlockKeys.type), isFalse);
      expect(jsonEncode(state.document.toJson()), before);
      expect(state.undoManager.undoStack.isEmpty, isTrue);
      await editor.close();
    }
    final editor = _editor(
      [
        _list(BulletedListBlockKeys.type, children: [_list(TodoListBlockKeys.type)]),
      ],
      containers: const [BulletedListBlockKeys.type],
    );
    editor.editorState.selection = Selection.single(path: [0, 0], startOffset: 0);
    expect(await changeCollabListType(editor.editorState, NumberedListBlockKeys.type), isFalse);
    expect(editor.editorState.undoManager.undoStack.isEmpty, isTrue);
    await editor.close();
  });

  test('container permission does not expand enter backspace or indentation', () async {
    final editor = _editor([
      _section([_list(TodoListBlockKeys.type)]),
    ]);
    addTearDown(editor.close);
    final state = editor.editorState;
    state.selection = Selection.single(path: [0, 0], startOffset: 0);
    final before = jsonEncode(state.document.toJson());
    expect(await handleCollabListEnter(state), isFalse);
    expect(canOutdentCollabListAtStart(state), isFalse);
    expect(await outdentCollabListAtStart(state), isFalse);
    expect(canChangeCollabListIndent(state, 1), isFalse);
    expect(await changeCollabListIndent(state, 1), isFalse);
    expect(jsonEncode(state.document.toJson()), before);
  });

  for (final callout in [false, true]) {
    test('default root and callout conversion remain available callout=$callout', () async {
      final list = _list(TodoListBlockKeys.type);
      final editor = _editor([
        callout ? _section([list], type: csesCalloutBlockType) : list,
      ], containers: const []);
      addTearDown(editor.close);
      final state = editor.editorState;
      final path = callout ? [0, 0] : [0];
      state.selection = Selection.single(path: path, startOffset: 1);
      expect(await changeCollabListType(state, BulletedListBlockKeys.type), isTrue);
      expect(state.getNodeAtPath(path)!.type, BulletedListBlockKeys.type);
      state.undoManager.undo();
      expect(state.getNodeAtPath(path)!.type, TodoListBlockKeys.type);
      expect(state.getNodeAtPath(path)!.attributes[TodoListBlockKeys.checked], isTrue);
    });
  }
}

/// 创建拥有[children]的纯本地正文，并以[containers]显式允许结构容器列表类型转换。
DocumentEditorController _editor(List<Node> children, {Iterable<String> containers = const ['custom-section']}) =>
    DocumentEditorController(
      document: Document(
        root: Node(type: PageBlockKeys.type, children: children),
      ),
      commandContext: EditorCommandContext(
        localOnly: true,
        configuration: EditorConfiguration(listConversionContainerTypes: containers),
      ),
    );

/// 用[type]为借用的[children]创建无Delta结构容器，默认使用测试自定义类型。
Node _section(List<Node> children, {String type = 'custom-section'}) => Node(type: type, children: children);

/// 创建[type]列表并保留可验证的富文本、原生提及及列表属性；[children]默认空用于扁平项。
Node _list(String type, {List<Node> children = const []}) => Node(
  type: type,
  attributes: {
    blockComponentDelta:
        (Delta()
              ..insert('甲', attributes: {AppFlowyRichTextKeys.bold: true})
              ..insert(
                '\uFFFC',
                attributes: {
                  'cses_inline_mention': '张三',
                  'cses_mention_id': 'u1',
                  'cses_mention_attributes': '{"mentionType":"user","mentionId":"u1"}',
                },
              )
              ..insert('乙😀', attributes: {AppFlowyRichTextKeys.italic: true}))
            .toJson(),
    csesBlockIndentAttribute: 2,
    blockComponentAlign: 'right',
    if (type == TodoListBlockKeys.type) TodoListBlockKeys.checked: true,
    if (type == NumberedListBlockKeys.type) ...{
      csesOrderedAttribute: const CollabOrdered(order: 4, start: 5).toJson(),
      csesOrderedNumberingAttribute: '{"start":5,"continuePrevious":false}',
    },
  },
  children: children,
);
