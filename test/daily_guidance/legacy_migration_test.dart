import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/file_journal_store.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 生成旧版实际三栏协议；[reflection]、[check]控制原可选栏目的文字。
Map<String, dynamic> _legacy({
  String reflection = '保留感悟',
  String check = '保留自检',
}) {
  final doc = Document(
    root: Node(
      type: 'page',
      children: [
        for (final item in [
          ('record', '原有记录'),
          ('reflection', reflection),
          ('self-check', check),
        ])
          Node(
            type: journalSectionType,
            attributes: {'section': item.$1},
            children: [
              paragraphNode(
                delta: Delta()..insert(item.$2, attributes: {'bold': true}),
              ),
            ],
          ),
      ],
    ),
  );
  try {
    return {
      'schemaVersion': 1,
      'templateId': 'ruled-daily',
      'templateVersion': 1,
      'id': 'journal-original',
      'date': '2026-10-21',
      'createdAt': '2026-10-21T01:02:03Z',
      'updatedAt': '2026-10-21T02:03:04Z',
      'timezoneOffsetMinutes': 480,
      'document': doc.toJson(),
    };
  } finally {
    doc.dispose();
  }
}

/// 检验真正旧版字节升级、失败保留、身份/日期/正文/格式与关闭区恢复。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'v1 nonempty document content and metadata survive migration exactly',
    () {
      final raw = _legacy();
      final draft = JournalDraft.fromJson(raw);
      expect(draft.needsMigration, isTrue);
      final json = draft.toJson();
      expect(json['schemaVersion'], 2);
      for (final key in [
        'id',
        'date',
        'createdAt',
        'updatedAt',
        'timezoneOffsetMinutes',
        'document',
      ]) {
        if (key == 'createdAt' || key == 'updatedAt') {
          expect(
            DateTime.parse(json[key] as String),
            DateTime.parse(raw[key] as String),
            reason: key,
          );
        } else {
          expect(json[key], raw[key], reason: key);
        }
      }
      expect(JournalDraft.fromJson(json).needsMigration, isFalse);
    },
  );
  test(
    'plain paste caret remains between inserted text and original suffix',
    () async {
      final dir = await Directory.systemTemp.createTemp('journal-caret-');
      final journal = await LocalJournalController.open(
        store: FileJournalStore(directory: dir, scope: 'a'),
      );
      try {
        final state = journal.editor.editorState;
        final node = state.getNodeAtPath([0, 0])!;
        await state.apply(state.transaction..insertText(node, 0, '前原文后'));
        state.selection = Selection.single(
          path: [0, 0],
          startOffset: 1,
          endOffset: 3,
        );
        AppFlowyClipboard.mockSetData(const AppFlowyClipboardData(text: '新内容'));
        await journal.pasteFromClipboard();
        expect(node.delta!.toPlainText(), '前新内容后');
        expect(state.selection!.end.offset, 4);
        state.undoManager.undo();
        state.undoManager.redo();
        expect(state.selection!.end.offset, 4);
      } finally {
        AppFlowyClipboard.mockSetData(null);
        await journal.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test('v1 empty optional content is retained closed rather than lost', () {
    final raw = _legacy(reflection: '', check: '');
    // Empty Delta.insert emits no run, matching the old app's actual empty paragraphs.
    final draft = JournalDraft.fromJson(raw);
    final doc = Document.fromJson(
      jsonDecode(draft.documentJson) as Map<String, dynamic>,
    );
    try {
      expect(doc.root.children.length, 1);
      expect(closedJournalSections(doc).map((n) => n.attributes['section']), [
        'reflection',
        'self-check',
      ]);
    } finally {
      doc.dispose();
    }
  });
  test(
    'first successful v2 disk save backs up exact v1 bytes and preserves account path',
    () async {
      final dir = await Directory.systemTemp.createTemp('journal-v1-');
      try {
        final file = File(p.join(dir.path, 'same-account.json'));
        final original = const JsonEncoder.withIndent('  ').convert(_legacy());
        await file.writeAsString(original, flush: true);
        final store = FileJournalStore(directory: dir, scope: 'same-account');
        final journal = await LocalJournalController.open(store: store);
        expect(journal.date, '2026-10-21');
        expect(journal.dirty, isTrue);
        expect(await journal.flush(), isTrue);
        expect(await File('${file.path}.v1.bak').readAsString(), original);
        expect(jsonDecode(await file.readAsString())['schemaVersion'], 2);
        await journal.close();
        final reopened = await LocalJournalController.open(store: store);
        expect(
          reopened.editor.editorState
              .getNodeAtPath([2, 0])!
              .delta!
              .toPlainText(),
          '保留自检',
        );
        await reopened.close();
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'partial backup cannot authorize overwrite without a complete matching backup',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'journal-backup-partial-',
      );
      try {
        final file = File(p.join(dir.path, 'a.json'));
        final original = jsonEncode(_legacy());
        await file.writeAsString(original);
        await File('${file.path}.v1.bak').writeAsString('{partial');
        final journal = await LocalJournalController.open(
          store: FileJournalStore(directory: dir, scope: 'a'),
        );
        expect(await journal.flush(), isTrue);
        final backups = await dir
            .list()
            .where((item) => item.path.endsWith('.bak'))
            .toList();
        expect(backups, hasLength(2));
        expect(await File('${file.path}.v1.bak').readAsString(), '{partial');
        final complete = backups.singleWhere(
          (item) => item.path != '${file.path}.v1.bak',
        );
        expect(await File(complete.path).readAsString(), original);
        await journal.close();
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'backup flush failure blocks migration and retry creates a complete atomic backup',
    () async {
      final dir = await Directory.systemTemp.createTemp('journal-backup-fail-');
      try {
        final file = File(p.join(dir.path, 'a.json'));
        final original = jsonEncode(_legacy());
        await file.writeAsString(original);
        final blocker = await Directory('${file.path}.v1.bak.tmp').create();
        final journal = await LocalJournalController.open(
          store: FileJournalStore(directory: dir, scope: 'a'),
        );
        expect(await journal.flush(), isFalse);
        expect(await file.readAsString(), original);
        expect(await File('${file.path}.v1.bak').exists(), isFalse);
        await blocker.delete();
        expect(await journal.flush(), isTrue);
        expect(await File('${file.path}.v1.bak').readAsString(), original);
        expect(await File('${file.path}.v1.bak.tmp').exists(), isFalse);
        await journal.close();
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'failed v2 commit leaves v1 bytes readable and preserves backup',
    () async {
      final dir = await Directory.systemTemp.createTemp('journal-v1-fail-');
      try {
        final file = File(p.join(dir.path, 'account.json'));
        final original = jsonEncode(_legacy());
        await file.writeAsString(original);
        await Directory('${file.path}.tmp').create();
        final store = FileJournalStore(directory: dir, scope: 'account');
        final journal = await LocalJournalController.open(store: store);
        expect(await journal.flush(), isFalse);
        expect(journal.dirty, isTrue);
        expect(await file.readAsString(), original);
        expect(await File('${file.path}.v1.bak').readAsString(), original);
        await journal.close();
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
