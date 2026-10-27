import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/file_journal_store.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_blockcraft_codec.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_surface.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 创建虚构桌面块；[id]为稳定身份，[kind]为flavour，[props]/[meta]/[children]为协议字段。
Map<String, dynamic> _block(
  String id,
  String kind, {
  Map<String, dynamic> props = const {},
  Map<String, dynamic> meta = const {},
  List<Object> children = const [],
}) => {
  'id': id,
  'flavour': kind,
  'nodeType': kind == 'root'
      ? 'root'
      : kind == 'callout'
      ? 'block'
      : 'editable',
  'props': props,
  'meta': meta,
  'children': children,
};

/// 把[children]包装为独立桌面根，保留根级自定义元数据用于双向校验。
Map<String, dynamic> _root(List<Object> children) =>
    _block('root', 'root', meta: {'audit': 'root-demo'}, children: children);

/// 将虚构[snapshot]实际落到借用的[store]，再由生产解析器打开；调用方关闭返回会话。
Future<LocalJournalController> _open(
  FileJournalStore store,
  Map<String, dynamic> snapshot,
) async {
  await store.write(
    JournalBlockCraftCodec.importSnapshot(
      snapshot,
      now: DateTime(2026, 10, 23),
    ),
  );
  return LocalJournalController.open(
    store: store,
    saveDelay: const Duration(hours: 1),
  );
}

/// 验证借用[journal]当前树的双向交换、真实文件保存和重开；结束时关闭[journal]。
/// [store]为原稿存储，[directory]为测试独占目录，[example]为可选归档示例名，默认不生成。
/// 反向导入使用独立文件，不覆盖源稿；两个新会话均在比较后关闭。
Future<void> _verifyExchangeAndReopen(
  LocalJournalController journal,
  FileJournalStore store,
  Directory directory, {
  String? example,
}) async {
  final expected = journal.exportBlockCraftSnapshot();
  final reverseStore = FileJournalStore(directory: directory, scope: 'reverse');
  final reverse = await _open(
    reverseStore,
    jsonDecode(jsonEncode(expected)) as Map<String, dynamic>,
  );
  try {
    expect(
      reverse.exportBlockCraftSnapshot()['children'],
      expected['children'],
    );
    expect(
      (reverse.exportBlockCraftSnapshot()['meta'] as Map)['audit'],
      'root-demo',
    );
  } finally {
    await reverse.close();
  }
  final reverseReopened = await LocalJournalController.open(
    store: reverseStore,
  );
  try {
    expect(
      reverseReopened.exportBlockCraftSnapshot()['children'],
      expected['children'],
    );
  } finally {
    await reverseReopened.close();
  }
  expect(await journal.flush(), true);
  await journal.close();
  final reopened = await LocalJournalController.open(store: store);
  try {
    expect(
      reopened.exportBlockCraftSnapshot()['children'],
      expected['children'],
    );
    expect(
      (reopened.exportBlockCraftSnapshot()['meta'] as Map)['audit'],
      'root-demo',
    );
  } finally {
    await reopened.close();
  }
  if (example != null &&
      const bool.fromEnvironment('GENERATE_BLOCKCRAFT_P1_EXAMPLES')) {
    File(
      '../docs/verification/blockcraft-json-exchange-20261023/$example',
    ).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(expected)}\n',
    );
  }
}

/// 验证两项P1在宿主真实命令、双向JSON、历史和文件持久化链上的完整性。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final kind in ['help', 'pilot', 'task']) {
    for (final type in ['heading', 'quote']) {
      test(
        'empty $type $kind retains business and stable id across Enter, history, JSON and file reopen',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'journal-p1-',
          );
          final store = FileJournalStore(directory: directory, scope: 'source');
          final journal = await _open(
            store,
            _root([
              _block(
                'entry-block',
                type == 'heading' ? 'paragraph' : 'blockquote',
                props: {
                  if (type == 'heading') 'heading': 2,
                  'fs': 28,
                  'custom': 'keep',
                },
                meta: {
                  'audit': 'entry-demo',
                  'mobileGuidance': {
                    'version': 1,
                    'role': 'content',
                    'section': 'record',
                    'business': {
                      'guidance_entry': kind,
                      'guidance_entry_id': 'entry-demo',
                      'guidance_done': true,
                    },
                  },
                },
              ),
            ]),
          );
          try {
            final state = journal.editor.editorState;
            state.selection = Selection.collapsed(Position(path: [0, 0]));
            final before = journal.exportBlockCraftSnapshot()['children'];
            expect(await handleDocumentParagraphEnter(state), true);
            final node = state.getNodeAtPath([0, 0])!;
            expect(node.type, ParagraphBlockKeys.type);
            expect(node.attributes['guidance_entry_id'], 'entry-demo');
            expect(node.attributes['guidance_entry'], kind);
            expect(node.attributes['guidance_done'], true);
            final after =
                journal.exportBlockCraftSnapshot()['children'] as List;
            final block = after.single as Map;
            expect(block['id'], 'entry-block');
            expect((block['meta'] as Map)['audit'], 'entry-demo');
            expect((block['props'] as Map)['custom'], 'keep');
            expect((block['props'] as Map)['fs'], isNull);
            state.undoManager.undo();
            await pumpEventQueue();
            expect(journal.exportBlockCraftSnapshot()['children'], before);
            state.undoManager.redo();
            await pumpEventQueue();
            expect(journal.exportBlockCraftSnapshot()['children'], after);
            expect(
              state.getNodeAtPath([0, 0])!.attributes['guidance_entry_id'],
              'entry-demo',
            );
            await _verifyExchangeAndReopen(
              journal,
              store,
              directory,
              example: kind == 'help' ? 'p1-fixed-$type-help.json' : null,
            );
          } finally {
            await journal.close();
            await directory.delete(recursive: true);
          }
        },
      );
    }
  }
  for (final inCallout in [false, true]) {
    testWidgets(
      'production journal Tab stays flat in ${inCallout ? 'callout' : 'section'} through history and exchange',
      (tester) async {
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('journal-tab-'),
        ))!;
        final store = FileJournalStore(directory: directory, scope: 'source');
        final items = [
          _block(
            'anchor',
            'paragraph',
            children: [
              {'insert': 'anchor'},
            ],
          ),
          _block(
            'todo',
            'todo',
            props: {'checked': 1, 'depth': 0},
            meta: {'audit': 'todo-demo'},
            children: [
              {
                'insert': '格式待办',
                'attributes': {'a:bold': true, 't:px': 22},
              },
              {
                'insert': {'mention': '测试人员'},
                'attributes': {'mentionId': 'user-demo', 'mentionType': 'user'},
              },
            ],
          ),
        ];
        final journal = (await tester.runAsync(
          () => _open(
            store,
            _root(
              inCallout
                  ? [_block('callout', 'callout', children: items)]
                  : items,
            ),
          ),
        ))!;
        try {
          final state = journal.editor.editorState;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: JournalSurface(
                  editorState: state,
                  preview: false,
                  header: const SizedBox(),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final editor = tester.widget<AppFlowyEditor>(
            find.byType(AppFlowyEditor),
          );
          final commands = editor.commandShortcutEvents;
          expect(
            commands.any(
              (event) => event.key == 'indent' || event.key == 'outdent',
            ),
            false,
          );
          final path = inCallout ? [0, 0, 1] : [0, 1];
          state.selection = Selection.collapsed(
            Position(path: path, offset: 1),
          );
          final before = journal.exportBlockCraftSnapshot()['children'];
          expect(
            commands
                .singleWhere((event) => event.key == 'cses-text-tab')
                .execute(state),
            KeyEventResult.handled,
          );
          await tester.pump();
          final todo = state.getNodeAtPath(path)!;
          expect(todo.children, isEmpty);
          expect(todo.attributes['checked'], true);
          expect(todo.attributes['bc.id'], 'todo');
          expect(todo.attributes['cses_collab_indent'], 1);
          final after = journal.exportBlockCraftSnapshot()['children'];
          final exportedTodo = inCallout
              ? (((after as List).single as Map)['children'] as List).last
                    as Map
              : (after as List).last as Map;
          expect((exportedTodo['props'] as Map)['depth'], 1);
          state.undoManager.undo();
          await tester.pump();
          expect(journal.exportBlockCraftSnapshot()['children'], before);
          state.undoManager.redo();
          await tester.pump();
          expect(journal.exportBlockCraftSnapshot()['children'], after);
          expect(
            commands
                .singleWhere((event) => event.key == 'cses-text-shift-tab')
                .execute(state),
            KeyEventResult.handled,
          );
          await tester.pump();
          expect(
            state.getNodeAtPath(path)!.attributes['cses_collab_indent'],
            0,
          );
          state.undoManager.undo();
          await tester.pump();
          expect(journal.exportBlockCraftSnapshot()['children'], after);
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          await tester.runAsync(
            () => _verifyExchangeAndReopen(
              journal,
              store,
              directory,
              example: !inCallout ? 'p1-fixed-todo-tab.json' : null,
            ),
          );
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(journal.close);
          await tester.runAsync(() => directory.delete(recursive: true));
        }
      },
    );
  }
  test(
    'host rejects direct and mixed structural nesting atomically and preserves the saved source',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'journal-invalid-tree-',
      );
      final store = FileJournalStore(directory: directory, scope: 'source');
      final journal = await _open(
        store,
        _root([
          _block(
            'anchor',
            'paragraph',
            children: [
              {'insert': 'anchor'},
            ],
          ),
          _block(
            'body',
            'paragraph',
            children: [
              {'insert': 'body'},
            ],
          ),
          _block(
            'todo',
            'todo',
            props: {'checked': 1, 'depth': 0},
            children: [
              {'insert': 'todo'},
            ],
          ),
        ]),
      );
      try {
        final state = journal.editor.editorState;
        final before = journal.exportBlockCraftSnapshot()['children'];
        await state.apply(
          state.transaction
            ..insertNode([0, 0, 0], paragraphNode(text: 'must not be dropped')),
        );
        expect(state.getNodeAtPath([0, 0])!.children, isEmpty);
        state.selection = Selection.collapsed(
          Position(path: [0, 2], offset: 1),
        );
        indentCommand.execute(state);
        await pumpEventQueue();
        expect(journal.exportBlockCraftSnapshot()['children'], before);
        state.selection = Selection(
          start: Position(path: [0, 1]),
          end: Position(path: [0, 2], offset: 4),
        );
        indentCommand.execute(state);
        await pumpEventQueue();
        expect(journal.exportBlockCraftSnapshot()['children'], before);
        expect(state.undoManager.undoStack, isEmpty);
        await _verifyExchangeAndReopen(journal, store, directory);
      } finally {
        await journal.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
