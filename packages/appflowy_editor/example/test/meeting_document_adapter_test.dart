import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:example/meeting/meeting_document_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Checks the meeting protocol fixture against the example's live adapter.
void main() {
  const adapter = MeetingDocumentAdapter();
  late Map<String, dynamic> sample;

  setUpAll(() {
    sample = Map<String, dynamic>.from(
      jsonDecode(File('assets/meeting/docDescription.json').readAsStringSync())
          as Map,
    );
  });

  test('the complete meeting sample survives an untouched round trip', () {
    final document = adapter.import(sample);
    addTearDown(document.dispose);

    expect(adapter.export(document), sample);
    expect(document.root.children.length, (sample['children'] as List).length);
    expect(
      document.root.children.map((node) => node.type),
      contains('cses_callout'),
    );
    expect(
      document.root.children.map((node) => node.type),
      contains('cses_attachment'),
    );
    expect(document.root.children.map((node) => node.type), contains('code'));
  });

  test('editing a text block keeps adjacent media and document metadata', () {
    final document = adapter.import(sample);
    addTearDown(document.dispose);
    final first = document.root.children.first;
    first.updateAttributes({'delta': (Delta()..insert('新的会议描述')).toJson()});

    final result = adapter.export(document);
    final children = result['children'] as List;
    expect((children.first as Map)['children'], [
      {'insert': '新的会议描述'},
    ]);
    expect(result['id'], sample['id']);
    expect(result['meta'], sample['meta']);
    expect(children[20], (sample['children'] as List)[20]);
  });

  test('imported text nodes accept editor text transactions', () async {
    final state = EditorState(document: adapter.import(sample));
    addTearDown(state.dispose);
    final first = state.document.root.children.first;
    expect(first.parent, same(state.document.root));
    expect(first.path, [0]);

    await state.apply(
      state.transaction..insertText(first, first.delta!.length, '可编辑'),
    );
    final exported =
        (adapter.export(state.document)['children'] as List).first as Map;
    expect(exported['children'], [
      {'insert': '会议描述可编辑'},
    ]);
  });

  test('todo and alignment edits update props without rewriting text runs', () {
    final document = adapter.import(sample);
    addTearDown(document.dispose);
    final todo = document.root.children.firstWhere(
      (node) => node.type == 'todo_list',
    );
    final quote = document.root.children.firstWhere(
      (node) => node.type == 'quote',
    );
    todo.updateAttributes({'checked': true});
    quote.updateAttributes({blockComponentAlign: 'left'});

    final output = adapter.export(document);
    final children = (output['children'] as List).cast<Map>();
    final todoOutput = children.firstWhere((node) => node['id'] == todo.id);
    final quoteOutput = children.firstWhere((node) => node['id'] == quote.id);
    expect((todoOutput['props'] as Map)['checked'], 1);
    expect((quoteOutput['props'] as Map)['textAlign'], 'left');
    expect(
      todoOutput['children'],
      (sample['children'] as List).cast<Map>().firstWhere(
        (node) => node['id'] == todo.id,
      )['children'],
    );
  });

  test('new paragraphs export as server editable nodes', () {
    final document = adapter.import(sample);
    addTearDown(document.dispose);
    document.root.insert(paragraphNode(text: '新增事项'));

    final result = adapter.export(document);
    final last = (result['children'] as List).last as Map;
    expect(last['flavour'], 'paragraph');
    expect(last['nodeType'], 'editable');
    expect(last['children'], [
      {'insert': '新增事项'},
    ]);
    expect(last['id'], isNotEmpty);
    expect(last['meta'], isA<Map>());
  });

  test('a new empty paragraph exports an explicit empty text run', () {
    final document = adapter.import(sample);
    addTearDown(document.dispose);
    document.root.insert(paragraphNode());

    final last = (adapter.export(document)['children'] as List).last as Map;
    expect(last['children'], [
      {'insert': ''},
    ]);
  });

  test(
    'media blocks can be inserted, edited, and deleted through transactions',
    () async {
      final state = EditorState(document: adapter.import(sample));
      addTearDown(state.dispose);
      final image = adapter.createBlock(
        'image',
        props: {'src': 'https://example.com/first.png', 'width': 320},
      );
      await state.apply(
        state.transaction..insertNode([0], image, deepCopy: false),
      );

      final inserted = state.document.root.children.first;
      expect(inserted.type, 'image');
      var first =
          (adapter.export(state.document)['children'] as List).first as Map;
      expect(first['flavour'], 'image');
      expect(first['nodeType'], 'block');
      expect((first['props'] as Map)['width'], 320);

      await state.apply(
        state.transaction..updateNode(
          inserted,
          adapter.updatedBlockAttributes(inserted, {
            'src': 'https://example.com/updated.png',
            'width': 640,
          }),
        ),
      );
      first = (adapter.export(state.document)['children'] as List).first as Map;
      expect((first['props'] as Map)['src'], 'https://example.com/updated.png');
      expect((first['props'] as Map)['width'], 640);

      await state.apply(state.transaction..deleteNode(inserted));
      expect(adapter.export(state.document), sample);
    },
  );

  test('a new callout contains an editable paragraph', () {
    final document = adapter.import(sample);
    addTearDown(document.dispose);
    document.root.insert(
      adapter.createBlock(
        'callout',
        props: {'prefix': '📌', 'backColor': '#FFE6CD'},
      ),
    );

    final last = (adapter.export(document)['children'] as List).last as Map;
    expect(last['flavour'], 'callout');
    expect(last['nodeType'], 'block');
    expect((last['children'] as List).single['flavour'], 'paragraph');
    expect(((last['children'] as List).single as Map)['children'], [
      {'insert': ''},
    ]);
  });
}
