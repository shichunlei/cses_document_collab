import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 从实际桌面安装版Schema生成的虚构多块夹具读取独立根快照。
Map<String, dynamic> _fixture() =>
    jsonDecode(File('test/fixtures/desktop-json-blocks.json').readAsStringSync()) as Map<String, dynamic>;

/// 按前序遍历借用的[snapshot]及子块，用于比较转换覆盖与业务属性。
Iterable<Map> _blocks(Map snapshot) sync* {
  yield snapshot;
  if (snapshot['nodeType'] == 'root' || snapshot['nodeType'] == 'block') {
    for (final child in snapshot['children'] as List) {
      yield* _blocks(child as Map);
    }
  }
}

/// 验证真实Schema夹具、原生编辑后的重新导出及实际对象渲染，不依赖原生协同库。
void main() {
  test('desktop block structures and attributes convert into editable nodes and survive local JSON', () {
    final original = _fixture();
    expect(_blocks(original).map((block) => block['flavour']).toSet(), BlockCraftJsonCodec.flavours);
    final document = BlockCraftJsonCodec.decode(original);
    final reopened = Document.fromJson(jsonDecode(jsonEncode(document.toJson())) as Map<String, dynamic>);
    try {
      final encoded = BlockCraftJsonCodec.encode(reopened);
      final before = {for (final block in _blocks(original)) block['id']: block};
      final after = {for (final block in _blocks(encoded)) block['id']: block};
      expect(after.keys, unorderedEquals(before.keys));
      for (final entry in before.entries) {
        expect(after[entry.key]!['flavour'], entry.value['flavour'], reason: '${entry.key}');
        expect(after[entry.key]!['nodeType'], entry.value['nodeType'], reason: '${entry.key}');
        for (final prop in (entry.value['props'] as Map).entries) {
          expect(
            (after[entry.key]!['props'] as Map)[prop.key],
            prop.value,
            reason: '${entry.value['flavour']}.${prop.key}',
          );
        }
      }
      expect(jsonEncode(reopened.toJson()), isNot(contains('rawSnapshot')));
      expect(jsonEncode(reopened.toJson()), isNot(contains('guidance_blockcraft_opaque')));
    } finally {
      document.dispose();
      reopened.dispose();
    }
  });

  test('inline objects and styles are converted at UTF16 object boundaries', () {
    final runs = [
      {
        'insert': '中文😀',
        'attributes': {'a:bold': true, 's:color': '#ff0000', 't:px': 24, 'a:sup': false},
      },
      {
        'insert': {'mention': '同名人员'},
        'attributes': {'mentionId': 'u1', 'mentionType': 'user', 'userId': 'u1'},
      },
      {
        'insert': {'mention': '同名人员'},
        'attributes': {'mentionId': 'u2', 'mentionType': 'user'},
      },
      {
        'insert': {'latex': 'x^2'},
      },
      {
        'insert': {'date': '2026-10-23'},
        'attributes': {'format': 'YYYY-MM-DD'},
      },
      {
        'insert': {
          'shape': jsonEncode({
            'props': {'shape': 'ellipse', 'fill': '#224c91'},
            'text': [
              {
                'insert': '形状内文字',
                'attributes': {'a:bold': true},
              },
            ],
          }),
        },
        'attributes': {'width': 120, 'height': 80},
      },
      {'insert': '\n'},
    ];
    final delta = BlockCraftJsonCodec.decodeInline(runs);
    final result = BlockCraftJsonCodec.encodeInline(delta);
    expect(result, runs);
    expect(delta.toPlainText().codeUnits.where((code) => code == 0xfffc).length, 5);
    expect(
      delta.whereType<TextInsert>().lastWhere((run) => run.text == '\uFFFC').attributes!['bc.e:shape'],
      isA<Map>(),
    );
  });

  test('null fields and cleared mention formatting survive persistence without reviving old styles', () {
    final snapshot = _fixture();
    final first = (snapshot['children'] as List).first as Map;
    (first['props'] as Map)['customNullable'] = null;
    (first['meta'] as Map)['customNullable'] = null;
    first['children'] = [
      {
        'insert': {'mention': '张三'},
        'attributes': {'mentionId': 'u1', 'mentionType': 'user', 'a:bold': true},
      },
    ];
    final document = BlockCraftJsonCodec.decode(snapshot);
    final paragraph = document.root.children.first;
    final attrs = {...paragraph.delta!.whereType<TextInsert>().first.attributes!}..remove('bold');
    paragraph.updateAttributes({
      'delta': [
        {'insert': '\uFFFC', 'attributes': attrs},
      ],
    });
    final reopened = Document.fromJson(jsonDecode(jsonEncode(document.toJson())) as Map<String, dynamic>);
    try {
      final encoded = BlockCraftJsonCodec.encode(reopened);
      final block = (encoded['children'] as List).first as Map;
      expect((block['props'] as Map).containsKey('customNullable'), true);
      expect((block['meta'] as Map).containsKey('customNullable'), true);
      expect(((block['children'] as List).first as Map)['attributes'], {'mentionId': 'u1', 'mentionType': 'user'});
    } finally {
      document.dispose();
      reopened.dispose();
    }
  });

  test('unknown plugins, duplicate ids and patch deltas fail instead of becoming opaque JSON', () {
    final snapshot = _fixture();
    (snapshot['children'] as List).add({...Map.from((snapshot['children'] as List).first as Map)});
    expect(() => BlockCraftJsonCodec.decode(snapshot), throwsFormatException);
    final unknown = _fixture();
    ((unknown['children'] as List).first as Map)['flavour'] = 'external-unknown';
    expect(() => BlockCraftJsonCodec.decode(unknown), throwsFormatException);
    final patch = _fixture();
    ((patch['children'] as List).first as Map)['children'] = [
      {'retain': 2},
    ];
    expect(() => BlockCraftJsonCodec.decode(patch), throwsFormatException);
  });

  testWidgets('converted shape, columns, date, person and weather render in the actual editor', (tester) async {
    final fixture = _fixture();
    fixture['children'] = (fixture['children'] as List)
        .where(
          (value) => {
            'shape',
            'sticker',
            'object-group',
            'placement-layout',
            'render-unit',
            'columns',
            'text-box',
            'word-art',
            'date-card',
            'person-card',
            'weather',
            'mind-map',
            'task-list',
          }.contains((value as Map)['flavour']),
        )
        .toList();
    final controller = DocumentEditorController(
      document: BlockCraftJsonCodec.decode(fixture),
      commandContext: const EditorCommandContext(localOnly: true),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DocumentEditorView(
            editorState: controller.editorState,
            preview: false,
            configuration: EditorViewConfiguration(blockBuilders: blockCraftSnapshotBuilders),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    for (final finder in [
      find.textContaining('示例城市'),
      find.text('2026年10月23日'),
      find.text('示例人员'),
      find.text('中心主题'),
    ]) {
      await tester.scrollUntilVisible(
        finder,
        200,
        scrollable: find
            .byWidgetPredicate((widget) => widget is Scrollable && widget.axisDirection == AxisDirection.down)
            .first,
        maxScrolls: 30,
      );
      expect(finder, findsOneWidget);
    }
    final paragraph = controller.editorState.document.root.children
        .firstWhere((node) => node.type == 'snapshot-text-box')
        .children
        .first;
    await controller.editorState.apply(
      controller.editorState.transaction..insertText(paragraph, paragraph.delta!.length, ' 已编辑'),
      withUpdateSelection: false,
    );
    await tester.pump();
    expect(jsonEncode(BlockCraftJsonCodec.encode(controller.editorState.document)), contains('已编辑'));

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.runAsync(controller.close);
  });
}
