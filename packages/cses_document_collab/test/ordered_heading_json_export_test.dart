import 'dart:convert';

import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:flutter_test/flutter_test.dart';

/// 创建带[level]标题样式的旧有序列表，保留编号、业务身份和富文本用于往返验证。
Map<String, dynamic> _ordered(int level) => {
  'id': 'legacy-ordered',
  'flavour': 'ordered',
  'nodeType': 'editable',
  'props': {
    'heading': level,
    'order': 4,
    'start': 5,
    'continuePrevious': false,
    'ms': 'decimal',
    'depth': 2,
    'custom': 'keep',
  },
  'meta': {'author': 'user'},
  'businessId': 'entry',
  'children': [
    {
      'insert': '旧列表😀',
      'attributes': {'a:bold': true, 't:px': 22},
    },
    {
      'insert': {'mention': '测试人员'},
      'attributes': {'mentionId': 'u1', 'mentionType': 'user'},
    },
  ],
};

/// 验证JSON导出的有序列表标题：1～6保留级别，旧7～9按正文，导出不修改源树。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (var level = 1; level <= 9; level++) {
    test('ordered heading $level exports the supported title or body style without changing source', () {
      final source = _ordered(level);
      final before = jsonDecode(jsonEncode(source));
      final node = BlockCraftJsonCodec.decodeBlock(source);
      final nodeBefore = jsonDecode(jsonEncode(node.toJson()));
      final exported = BlockCraftJsonCodec.encodeBlock(node);
      final expectedProps = Map<String, dynamic>.from(source['props'] as Map);
      if (level > 6) expectedProps.remove('heading');

      expect(exported['flavour'], 'ordered');
      expect(exported['props'], expectedProps);
      expect(exported['id'], source['id']);
      expect(exported['meta'], source['meta']);
      expect(exported['businessId'], source['businessId']);
      expect(exported['children'], source['children']);
      expect(source, before);
      expect(node.toJson(), nodeBefore);

      final reopened = BlockCraftJsonCodec.decodeBlock(exported);
      expect(BlockCraftJsonCodec.encodeBlock(reopened), exported);
    });
  }

  for (final current in [2, 7, null]) {
    test('ordered heading export reads the current field $current instead of the archived legacy value', () {
      final node = BlockCraftJsonCodec.decodeBlock(_ordered(9));
      node.updateAttributes({
        paragraphPropertyAttribute('heading'): jsonEncode(current == null ? <String, dynamic>{} : {'value': current}),
      });
      final before = jsonDecode(jsonEncode(node.toJson()));
      final props = BlockCraftJsonCodec.encodeBlock(node)['props'] as Map;
      if (current == 2) {
        expect(props['heading'], 2);
      } else {
        expect(props.containsKey('heading'), isFalse);
      }
      expect(props['start'], 5);
      expect(node.toJson(), before);
    });
  }

  test('document JSON encode and decode preserve ordered bodies alongside H1-H6', () {
    final document = BlockCraftJsonCodec.decode({
      'id': 'root',
      'flavour': 'root',
      'nodeType': 'root',
      'props': <String, dynamic>{},
      'meta': <String, dynamic>{},
      'children': [
        for (var level = 1; level <= 9; level++) {..._ordered(level), 'id': 'ordered-$level'},
      ],
    });
    try {
      final exported = BlockCraftJsonCodec.encode(document);
      final children = exported['children'] as List;
      for (var level = 1; level <= 9; level++) {
        final block = children[level - 1] as Map;
        expect(block['flavour'], 'ordered');
        expect((block['props'] as Map)['heading'], level <= 6 ? level : isNull);
      }
      final reopened = BlockCraftJsonCodec.decode(jsonDecode(jsonEncode(exported)) as Map<String, dynamic>);
      try {
        expect(BlockCraftJsonCodec.encode(reopened), exported);
      } finally {
        reopened.dispose();
      }
    } finally {
      document.dispose();
    }
  });
}
