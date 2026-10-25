import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/blockcraft_json_codec.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/model/collab_block_lock.dart';
import 'package:cses_document_collab/src/editor/collab_person_card_settings.dart';
import 'package:cses_document_collab/src/editor/core/document_editor_controller.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/model/collab_person_card.dart';
import 'package:cses_document_collab/src/ui/modal/collab_person_card_visual.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 人员卡片定格协议、稳定身份历史、草稿保护与原生布局回归。
void main() {
  test('desktop frozen JSON, typography and legacy scales are read without rewriting', () {
    expect(CollabPersonCardData.read({'name': '张三'}), isNull);
    expect(CollabPersonCardData.read('{"name":""}'), isNull);
    final props = {'person': _person.encode(), 'width': 366, 'style': 'row', 'fsr': '- 18', 'dept': 'on'};
    final card = CollabPersonCard(props);
    expect(card.person!.description, '研发部 / 工程师');
    expect(card.contentScale, 2);
    expect(card.fonts, [15, 18]);
    expect(card.departmentPosition, 'right');
    expect(CollabPersonCard({...props, 'sc': 1}).contentScale, 1);
    expect(CollabPersonCard({'style': 'column', 'dept': 'on'}).departmentPosition, 'below');
    expect(props.containsKey('sc'), isFalse);
  });

  test('field edits, reorder, undo preserve identity and frozen values', () async {
    final published = <List<CollabEditorBlock>>[];
    final adapter = _adapter(published.add);
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    expect(
      await changeCollabPersonCardProperties(state, 'person', {'style': 'column', 'dept': 'above'}),
      isTrue,
    );
    expect(jsonDecode(published.last.first.resource!.propertyEdits!), {
      'style': {'value': 'column'},
      'dept': {'value': 'above'},
    });
    final updated = adapter.blocks;
    await adapter.replaceFromRemote([updated.last, updated.first]);
    state.undoManager.undo();
    await pumpEventQueue();
    expect(adapter.blocks.last.resource!.values['style'], 'row');
    expect(adapter.blocks.last.resource!.values['person'], _person.encode());
    state.undoManager.redo();
    await pumpEventQueue();
    expect(adapter.blocks.last.resource!.values['dept'], 'above');
    for (final entry in {
      'style': 'future',
      'sc': 0,
      'person': {},
      'width': -1,
      'dept': false,
      'url': 'https://example.test',
    }.entries) {
      expect(await changeCollabPersonCardProperty(state, 'person', entry.key, entry.value), isFalse);
    }
  });

  test('insert, preceding backspace and undo restore fixed JSON and sc format marker', () async {
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [CollabEditorBlock(id: 'p', blockType: 'paragraph', text: '')],
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);
    final landing = await insertCollabPersonCard(
      adapter.editorState,
      Selection.single(path: [0], startOffset: 0),
      values: {'person': _person.encode()},
    );
    final inserted = adapter.blocks.first;
    expect(inserted.blockType, 'person-card');
    expect(inserted.resource!.values['sc'], 1);
    adapter.editorState.selection = landing;
    expect(await deletePreviousUrlBackedBlock(adapter.editorState), isTrue);
    adapter.editorState.undoManager.undo();
    await pumpEventQueue();
    expect(adapter.blocks.first.id, inserted.id);
    expect(adapter.blocks.first.resource!.values['person'], _person.encode());
  });

  test('JSON native import, clearing and reexport preserve opaque props and meta', () async {
    final fixture =
        jsonDecode(await File('rust/tests/fixtures/blockcraft-person-card.json').readAsString())
            as Map<String, dynamic>;
    fixture['children'] = [(fixture['children'] as List).first];
    final owner = DocumentEditorController(document: BlockCraftJsonCodec.decode(fixture));
    addTearDown(owner.close);
    expect(owner.editorState.document.root.children.single.type, 'person-card');
    await changeCollabPersonCardProperty(owner.editorState, 'person-0', 'fsr', '22');
    await changeCollabPersonCardProperty(owner.editorState, 'person-0', 'fsr', null);
    final card = (BlockCraftJsonCodec.encode(owner.editorState.document)['children'] as List).single;
    expect(card['props'].containsKey('fsr'), isFalse);
    expect(jsonDecode(card['props']['person'])['name'], '张三');
    expect(card['props']['sc'], 1);
    expect(card['props']['futureProp'], {'preserve': true});
    expect(card['meta']['audit'], 'desktop');
  });

  testWidgets('cancel writes nothing, apply once and undo preserves frozen data', (tester) async {
    final adapter = _adapter();
    await _settingsHost(tester, adapter.editorState);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('person-card-style-previous')));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(adapter.editorState.undoManager.undoStack, isEmpty);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('person-card-style-previous')));
    await tester.tap(find.byKey(const ValueKey('person-card-apply')));
    await tester.pumpAndSettle();
    expect(adapter.blocks.first.resource!.values['style'], 'column');
    expect(adapter.blocks.first.resource!.values['person'], _person.encode());
    expect(adapter.editorState.undoManager.undoStack.isNonEmpty, isTrue);
    adapter.editorState.undoManager.undo();
    await tester.pump();
    expect(adapter.blocks.first.resource!.values['style'], 'row');
    await tester.pumpWidget(const SizedBox());
    adapter.dispose();
  });

  testWidgets('revoking and restoring edit permission keeps old draft invalid', (tester) async {
    final adapter = _adapter();
    final state = adapter.editorState;
    await _settingsHost(tester, state);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('person-card-style-next')));
    state.editable = false;
    state.editable = true;
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('person-card-apply'))).onPressed, isNull);
    expect(adapter.editorState.undoManager.undoStack, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    adapter.dispose();
  });

  testWidgets('old draft remains invalid after lock/unlock and remote edits', (tester) async {
    final adapter = _adapter();
    final locks = CollabBlockLocks(
      editor: adapter.editorState,
      userId: 'u1',
      canUnlock: (_) => false,
      commit: (_, _, _) async {},
    );
    locks.update(const [CollabBlockLockState(blockId: 'person')]);
    await _settingsHost(tester, adapter.editorState);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    locks.update(const [CollabBlockLockState(blockId: 'person', sourceId: 'person', ownerId: 'u2')]);
    locks.update(const [CollabBlockLockState(blockId: 'person')]);
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('person-card-apply'))).onPressed, isNull);
    expect(await changeCollabPersonCardProperty(adapter.editorState, 'person', 'dept', 'off'), isTrue);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    locks.dispose();
    adapter.dispose();
  });

  for (final style in collabPersonCardStyles.keys) {
    testWidgets('native $style wraps long text within narrow fixed frame', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                child: MediaQuery(
                  data: const MediaQueryData(textScaler: TextScaler.linear(2.2)),
                  child: CollabPersonCardVisual(
                    card: CollabPersonCard({
                      'style': style,
                      'sc': 1,
                      'width': 280,
                      'height': 180,
                      'dept': 'right',
                      'avatar': 'rounded',
                      'avatarSize': 'large',
                      'person': const CollabPersonCardData(
                        name: '很长的人员姓名 LongEnglishName',
                        pinyin: 'ZHANG SAN',
                        description: '部门 / 很长的职务描述',
                      ).encode(),
                    }),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('很长的人员姓名 LongEnglishName'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

/// 定格测试资料，无头像网络请求。
const _person = CollabPersonCardData(name: '张三', pinyin: 'ZHANG SAN', description: '研发部 / 工程师');

/// 创建独立适配器，[onChanged]接收本地补丁；由调用方释放。
AppFlowyBlockEditorAdapter _adapter([void Function(List<CollabEditorBlock>)? onChanged]) =>
    AppFlowyBlockEditorAdapter(
      initialBlocks: [
        CollabEditorBlock(
          id: 'person',
          blockType: 'person-card',
          text: '',
          resource: CollabResource.fromValues({
            'person': _person.encode(),
            'style': 'row',
            'sc': 1,
            'dept': 'on',
          }),
        ),
        const CollabEditorBlock(id: 'p', blockType: 'paragraph', text: 'tail'),
      ],
      onLocalBlocksChanged: onChanged ?? (_) {},
    );

/// 在借用[tester]/[state]的路由中打开真实底部设置，不释放编辑器。
Future<void> _settingsHost(WidgetTester tester, EditorState state) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => await showCollabPersonCardSettings(context, state, 'person'),
            child: const Text('设置'),
          ),
        ),
      ),
    ),
  );
}
