import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_blockcraft_codec.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_exchange_keys.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_json_files.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_store.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_controller.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 交换回归的独立内存存储，按生产模型执行持久化往返。
class _Store implements JournalStore {
  /// [draft]是此存储独占的初始内容。
  _Store(this.draft);

  /// 此测试存储持有的独立可恢复草稿。
  JournalDraft? draft;

  /// 返回已保存的独立草稿。
  @override
  Future<JournalDraft?> read() async => draft;

  /// 以生产解析器隔离并保存[value]，不访问用户目录。
  @override
  Future<void> write(JournalDraft value) async =>
      draft = JournalDraft.fromJson(value.toJson());
}

/// 文件框替身；验证页面调用实际转换、独立存储和导出，而不操作系统文件。
class _Files implements JournalJsonFiles {
  /// 待选取的独立桌面快照。
  Map<String, dynamic>? imported;

  /// 最后一次系统保存框接收的JSON。
  Map<String, dynamic>? exported;

  /// 导入后打开的独立存储。
  _Store? child;

  /// 返回测试提供的桌面根快照。
  @override
  Future<Map<String, dynamic>?> pick() async => imported;

  /// 保存独立[snapshot]并接受建议[fileName]，模拟完成下载。
  @override
  Future<bool> save(Map<String, dynamic> snapshot, String fileName) async {
    exported = jsonDecode(jsonEncode(snapshot)) as Map<String, dynamic>;
    return true;
  }

  /// 为[draft]创建独立存储；[scope]为调用页面的账号分区。
  @override
  Future<JournalStore> createImportedStore(
    JournalDraft draft,
    String scope,
  ) async => child = _Store(draft);
}

/// 读取前轮使用生产模型生成的虚构三栏、用户和业务条目示例。
JournalDraft _sample() => JournalDraft.fromJson(
  jsonDecode(
        File(
          '../docs/verification/offline-journal-20261023/daily-guidance-sample.json',
        ).readAsStringSync(),
      )
      as Map<String, dynamic>,
);

/// 验证完整业务往返、桌面编辑后的真实更新及页面导入导出入口。
void main() {
  test(
    'journal formats, mentions, todo states, business ids and date survive both directions',
    () {
      final sample = _sample();
      final snapshot = JournalBlockCraftCodec.exportDraft(sample);
      final block = (snapshot['children'] as List).whereType<Map>().firstWhere(
        (node) =>
            node['id'] != null &&
            (node['children'] as List).any(
              (run) =>
                  (run as Map)['insert'] is String &&
                  '${run['insert']}'.contains('今日成果'),
            ),
      );
      expect(((block['children'] as List).first as Map)['attributes'], {
        'a:bold': true,
      });
      final roundTrip = JournalBlockCraftCodec.importSnapshot(snapshot);
      expect(roundTrip.date, sample.date);
      final document = Document.fromJson(
        jsonDecode(roundTrip.documentJson) as Map<String, dynamic>,
      );
      try {
        expect(document.root.children.length, 3);
        final nodes = journalContentNodes(document.root.children).toList();
        expect(
          nodes.where(
            (node) => node.attributes['guidance_entry_id'] == 'sample-help-001',
          ),
          hasLength(1),
        );
        expect(
          nodes.where(
            (node) =>
                node.attributes['guidance_entry_id'] == 'sample-pilot-001',
          ),
          hasLength(1),
        );
        expect(
          nodes
              .where((node) => node.type == 'todo_list')
              .map((node) => node.attributes['checked']),
          [true, true, false],
        );
        final attrs = nodes
            .expand(
              (node) =>
                  node.delta?.whereType<TextInsert>() ?? const <TextInsert>[],
            )
            .map((run) => run.attributes ?? {})
            .toList();
        expect(
          attrs.where((value) => value['cses_mention_id'] == 'user_demo_001'),
          hasLength(1),
        );
      } finally {
        document.dispose();
      }
      final again = JournalBlockCraftCodec.exportDraft(roundTrip);
      expect(jsonEncode(again), contains('sample-help-001'));
      expect(jsonEncode(again), contains('user_demo_003'));
      if (const bool.fromEnvironment('GENERATE_BLOCKCRAFT_EXAMPLES')) {
        File(
          '../docs/verification/blockcraft-json-exchange-20261023/fixes-converted-journal.json',
        ).writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(snapshot)}\n',
        );
        File(
          '../docs/verification/blockcraft-json-exchange-20261023/fixes-restored-mobile.json',
        ).writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(roundTrip.toJson())}\n',
        );
      }
    },
  );

  test(
    'all enabled formats, repeated objects and independent business/native checked state survive',
    () {
      final base = JournalDraft.blank(DateTime(2026, 10, 23));
      final document = Document.fromJson(
        jsonDecode(base.documentJson) as Map<String, dynamic>,
      );
      document.root.children.first.children.first.updateAttributes({
        'delta': [
          {
            'insert': '中文😀\n',
            'attributes': {
              'bold': true,
              'italic': true,
              'underline': true,
              'strikethrough': true,
              'code': true,
              'font_color': '0x80112233',
              'bg_color': '0xffaabbcc',
              't:px': 24,
              'cses_superscript': true,
              'cses_subscript': false,
            },
          },
          {
            'insert': '\uFFFC\uFFFC',
            'attributes': {
              'cses_inline_mention': '张三',
              'cses_mention_id': 'u1',
            },
          },
        ],
        'guidance_entry': 'task',
        'guidance_entry_id': 'entry-1',
        'guidance_done': true,
      });
      final draft = JournalDraft(
        id: base.id,
        date: base.date,
        createdAt: base.createdAt,
        updatedAt: base.updatedAt,
        timezoneOffsetMinutes: base.timezoneOffsetMinutes,
        documentJson: jsonEncode(document.toJson()),
      );
      document.dispose();
      final snapshot = JournalBlockCraftCodec.exportDraft(draft);
      final target = (snapshot['children'] as List).last as Map;
      expect(target['flavour'], 'todo');
      expect((target['props'] as Map)['checked'], 1);
      (target['props'] as Map)['checked'] = 0;
      final restored = JournalBlockCraftCodec.importSnapshot(snapshot);
      final body = Document.fromJson(
        jsonDecode(restored.documentJson) as Map<String, dynamic>,
      );
      try {
        final node = body.root.children.first.children.first;
        expect(node.type, 'paragraph');
        expect(node.attributes['guidance_done'], false);
        expect(node.delta!.toPlainText(), '中文😀\n\uFFFC\uFFFC');
        expect(
          node.delta!.whereType<TextInsert>().first.attributes!['t:px'],
          24,
        );
        expect(
          node.delta!.whereType<TextInsert>().first.attributes!['font_color'],
          'rgba(17, 34, 51, ${128 / 255})',
        );
      } finally {
        body.dispose();
      }
    },
  );

  testWidgets(
    'JSON menu exports live edits and opens a desktop snapshot in a separate editable route',
    (tester) async {
      final store = _Store(_sample());
      final files = _Files()
        ..imported = JournalBlockCraftCodec.exportDraft(_sample());
      await tester.binding.setSurfaceSize(const Size(600, 1100));
      await tester.pumpWidget(
        MaterialApp(
          home: LocalJournalPage(store: store, jsonFiles: files),
        ),
      );
      await tester.pumpAndSettle();
      final state = tester
          .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
          .editorState;
      final node = state.getNodeAtPath([0, 0])!;
      await state.apply(state.transaction..insertText(node, 0, '实时编辑 '));
      await tester.tap(find.byKey(const ValueKey('journal-json-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出桌面JSON'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        for (
          var attempt = 0;
          attempt < 100 && files.exported == null;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(jsonEncode(files.exported), contains('实时编辑'));
      await tester.tap(find.byKey(const ValueKey('journal-json-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开桌面JSON'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        for (var attempt = 0; attempt < 100 && files.child == null; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(files.child, isNotNull);
      expect(find.byType(AppFlowyEditor), findsOneWidget);
      final imported = tester
          .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
          .editorState;
      expect(identical(imported, state), false);
      expect(
        imported.document.root.attributes[journalDesktopImportAttribute],
        true,
      );
      final text = imported.getNodeAtPath([0, 0])!;
      await imported.apply(imported.transaction..insertText(text, 0, '反向编辑 '));
      expect(text.delta!.toPlainText(), startsWith('反向编辑'));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(null);
    },
  );

  test(
    'real controller export has no debounce delay and returns detached JSON',
    () async {
      final journal = await LocalJournalController.open(
        store: _Store(_sample()),
        saveDelay: const Duration(days: 1),
      );
      final node = journal.editor.editorState.getNodeAtPath([0, 0])!;
      await journal.editor.editorState.apply(
        journal.editor.editorState.transaction..insertText(node, 0, '导出前'),
      );
      final snapshot = journal.exportBlockCraftSnapshot();
      await journal.editor.editorState.apply(
        journal.editor.editorState.transaction..insertText(node, 0, '导出后'),
      );
      expect(jsonEncode(snapshot), contains('导出前'));
      expect(jsonEncode(snapshot), isNot(contains('导出后')));
      await journal.close();
    },
  );

  test(
    'stable block ids survive saving and reopening without entering business attributes',
    () async {
      final store = _Store(_sample());
      final first = await LocalJournalController.open(
        store: store,
        saveDelay: const Duration(days: 1),
      );
      final state = first.editor.editorState;
      final node = state.getNodeAtPath([0, 0])!;
      await state.apply(state.transaction..insertText(node, 0, '稳定身份'));
      final before = first.exportBlockCraftSnapshot();
      final body = jsonEncode(state.document.toJson());
      await first.flush();
      expect(store.draft!.documentJson, body);
      await first.close();
      final reopened = await LocalJournalController.open(store: store);
      final after = reopened.exportBlockCraftSnapshot();
      expect(
        (after['children'] as List).map((block) => (block as Map)['id']),
        (before['children'] as List).map((block) => (block as Map)['id']),
      );
      await reopened.close();
    },
  );

  test(
    'desktop blocks outside journal capabilities are converted into real nested native nodes',
    () {
      final source =
          jsonDecode(
                File(
                  '../test/fixtures/desktop-json-blocks.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final draft = JournalBlockCraftCodec.importSnapshot(
        source,
        now: DateTime(2026, 10, 23),
      );
      final doc = Document.fromJson(
        jsonDecode(draft.documentJson) as Map<String, dynamic>,
      );
      try {
        expect(
          journalContentNodes(
            doc.root.children,
          ).where((node) => node.type == 'snapshot-shape'),
          isNotEmpty,
        );
        expect(
          journalContentNodes(
            doc.root.children,
          ).where((node) => node.type == 'table-cell'),
          isNotEmpty,
        );
        final exported = JournalBlockCraftCodec.exportDraft(draft);
        expect(doc.root.attributes[journalPlainDesktopAttribute], true);
        expect(
          (exported['children'] as List).length,
          (source['children'] as List).length,
        );
        final nodes = (exported['children'] as List).whereType<Map>().where(
          (block) =>
              (block['meta'] as Map)[journalBlockCraftNamespace] is Map &&
              ((block['meta'] as Map)[journalBlockCraftNamespace]
                      as Map)['role'] !=
                  'section',
        );
        expect(
          nodes.map((node) => node['flavour']),
          (source['children'] as List).map((node) => (node as Map)['flavour']),
        );
        expect(draft.documentJson, isNot(contains('rawSnapshot')));
      } finally {
        doc.dispose();
      }
    },
  );
}
