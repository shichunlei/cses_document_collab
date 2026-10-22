import 'dart:convert';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter_test/flutter_test.dart';

/// 检查恢复文件的初始化快照边界，拒绝损坏或夹带额外正文属性的数据。
void main() {
  test('HTTP projection preserves IDs, metadata and empty Delta without mutable aliasing', () {
    final snapshot = _snapshot();
    final prepared = PreparedDocument.fromSnapshotJson(jsonEncode(snapshot));
    final diffs = prepared.insertDiffs;
    expect(diffs[0]['children'], ['paragraph']);
    expect(diffs[0]['parentId'], isNull);
    expect(diffs[1]['content'], isEmpty);
    expect(diffs[1].containsKey('children'), isFalse);
    expect(diffs[1]['parentId'], 'doc');
    expect(diffs.every((d) => d['mode'] == 'Insert'), isTrue);
    (diffs[0]['meta'] as Map).clear();
    (diffs[1]['props'] as Map)['depth'] = 8;
    expect(prepared.insertDiffs[0]['meta'], snapshot['meta']);
    expect(prepared.insertDiffs[1]['props'], {'depth': 0});
  });
  test('invalid root, text or extra props never become initial HTTP writes', () {
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (s) => s['id'] = '',
      (s) => s['props'] = {'readonly': true},
      (s) => s['children'][0]['children'] = [
        {'insert': '已有正文'},
      ],
      (s) => s['children'][0]['props'] = {'depth': 0, 'heading': 1},
      (s) => s['children'][0]['id'] = 'doc',
      (s) => s['meta']['lastModified']['user'] = 'other-user',
      (s) => s['meta']['createdTime'] = -1,
    ]) {
      final snapshot = _snapshot();
      mutate(snapshot);
      expect(() => PreparedDocument.fromSnapshotJson(jsonEncode(snapshot)), throwsFormatException);
    }
  });
}

/// 返回独立、完整的原生初始快照样本。
Map<String, dynamic> _snapshot() => {
  'id': 'doc',
  'flavour': 'root',
  'nodeType': 'root',
  'props': <String, dynamic>{},
  'meta': {
    'createdTime': 1792584000000,
    'lastModified': <String, dynamic>{'time': 1792584000000, 'user': null},
  },
  'children': [
    {
      'id': 'paragraph',
      'flavour': 'paragraph',
      'nodeType': 'editable',
      'props': {'depth': 0},
      'meta': <String, dynamic>{},
      'children': <dynamic>[],
    },
  ],
};
