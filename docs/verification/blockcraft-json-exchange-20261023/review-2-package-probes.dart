import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_indent.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 创建虚构独立块；[kind]/[type]为桌面类型，[props]/[meta]/[children]为真实协议字段。
Map<String, dynamic> _block(
  String kind,
  String type, {
  Map<String, dynamic> props = const {},
  Map<String, dynamic> meta = const {},
  List<Object> children = const [],
}) => {'id': kind, 'flavour': kind, 'nodeType': type, 'props': props, 'meta': meta, 'children': children};

/// 按正式视图的Tab命令顺序验证导出不漏掉子待办，不调用协同或业务服务。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('hardware Tab command fallback must not create unexportable todo nesting', () async {
    final editor = DocumentEditorController(
      document: BlockCraftJsonCodec.decode(
        _block(
          'root',
          'root',
          children: [
            _block(
              'paragraph',
              'editable',
              children: [
                {'insert': 'anchor'},
              ],
            ),
            _block(
              'todo',
              'editable',
              props: {'checked': 1},
              children: [
                {'insert': 'todo'},
              ],
            ),
          ],
        ),
      ),
      commandContext: const EditorCommandContext(localOnly: true),
    );
    try {
      final state = editor.editorState;
      expect(editor.commandContext.configuration.structuralIndentation, true);
      state.selection = Selection.collapsed(Position(path: [1], offset: 4));
      expect(collabParagraphTabCommand.execute(state), KeyEventResult.ignored);
      expect(indentCommand.execute(state), KeyEventResult.handled);
      await pumpEventQueue();
      expect(state.getNodeAtPath([0, 0])!.type, TodoListBlockKeys.type);
      expect(state.getNodeAtPath([0, 0])!.attributes['checked'], true);
      expect(jsonEncode(BlockCraftJsonCodec.encode(state.document)), contains('todo'));
    } finally {
      await editor.close();
    }
  });
}
