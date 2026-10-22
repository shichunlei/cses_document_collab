import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/guidance_entries.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/guidance_people.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_store.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_surface.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 独立保存JSON快照的测试存储，不共享编辑器中的可变文档。
final class _MemoryStore implements JournalStore {
  /// 最近成功保存的快照，null表示没有既有草稿。
  JournalDraft? saved;

  /// 读取独立的已保存快照，缺失时返回null。
  @override
  Future<JournalDraft?> read() async =>
      saved == null ? null : JournalDraft.fromJson(saved!.toJson());

  /// 将[draft]往返JSON后保存，模拟持久化不会保留正文对象引用。
  @override
  Future<void> write(JournalDraft draft) async =>
      saved = JournalDraft.fromJson(draft.toJson());
}

/// 从[tester]中借用生产页面实际配置的编辑器，避免测试另造快捷键。
AppFlowyEditor _editor(WidgetTester tester) =>
    tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));

/// 在[tester]挂载借用[store]的真实会话与生产正文，插入前后文字及已知引用。
Future<LocalJournalController> _mount(
  WidgetTester tester,
  _MemoryStore store,
) async {
  final journal = await LocalJournalController.open(
    store: store,
    saveDelay: const Duration(days: 1),
  );
  final state = journal.editor.editorState;
  final delta = Delta()
    ..insert('前')
    ..addAll(
      guidanceMentionDelta(const [GuidancePerson(id: 'person', name: '张三')]),
    )
    ..insert('后');
  await state.apply(
    state.transaction..updateNode(state.getNodeAtPath([0, 0])!, {
      blockComponentDelta: delta.toJson(),
    }),
    skipHistoryDebounce: true,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: JournalSurface(
          editorState: state,
          preview: false,
          header: const SizedBox.shrink(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return journal;
}

/// 在[tester]移除编辑视图后等待[journal]保存并释放，避免借用者访问已关闭资源。
Future<void> _unmount(
  WidgetTester tester,
  LocalJournalController journal,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  await tester.runAsync(journal.close);
}

/// 验证生产编辑器的快捷键调用宿主端口，复制结果可读且剪切失败不会丢失原文。
void main() {
  for (final cut in [false, true]) {
    testWidgets(
      'production ${cut ? 'cut' : 'copy'} shortcut expands mention and the result pastes as valid text',
      (tester) async {
        String? clipboard;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String;
            } else if (call.method == 'Clipboard.getData') {
              return {'text': clipboard};
            }
            return null;
          },
        );
        final store = _MemoryStore();
        final journal = await _mount(tester, store);
        final state = journal.editor.editorState;
        try {
          final node = state.getNodeAtPath([0, 0])!;
          state.selection = Selection.single(
            path: [0, 0],
            startOffset: node.delta!.length,
            endOffset: 0,
          );
          final commands = _editor(tester).commandShortcutEvents;
          expect(
            commands.where(
              (event) =>
                  event.key == copyCommand.key || event.key == cutCommand.key,
            ),
            isEmpty,
          );
          final shortcut = commands.singleWhere(
            (event) => event.key == (cut ? 'journal-cut' : 'journal-copy'),
          );
          expect(shortcut.handler(state), KeyEventResult.handled);
          await tester.pump();
          expect(clipboard, '前@张三 后');
          expect(clipboard, isNot(contains('\uFFFC')));
          expect(node.delta!.toPlainText(), cut ? '' : '前\uFFFC 后');
          state.selection = Selection.single(
            path: [0, 0],
            startOffset: 0,
            endOffset: node.delta!.length,
          );
          expect(
            commands
                .singleWhere((event) => event.key == 'journal-ctrl+v')
                .handler(state),
            KeyEventResult.handled,
          );
          await tester.pump();
          expect(node.delta!.toPlainText(), '前@张三 后');
          expect(
            node.delta!.every(
              (operation) =>
                  operation.attributes?[guidanceMentionAttribute] == null,
            ),
            isTrue,
          );
          validateJournalDocument(state.document);
          expect(await tester.runAsync(journal.flush), isTrue);
          final restored = Document.fromJson(
            jsonDecode(store.saved!.documentJson) as Map<String, dynamic>,
          );
          try {
            validateJournalDocument(restored);
            expect(restored.nodeAtPath([0, 0])!.delta!.toPlainText(), '前@张三 后');
          } finally {
            restored.dispose();
          }
          expect(tester.takeException(), isNull);
        } finally {
          await _unmount(tester, journal);
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
          AppFlowyClipboard.mockSetData(null);
        }
      },
    );
  }

  testWidgets(
    'production cut shortcut reports a failed clipboard write and keeps the saved mention',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(code: 'clipboard-unavailable');
          }
          return null;
        },
      );
      final store = _MemoryStore();
      final journal = await _mount(tester, store);
      final state = journal.editor.editorState;
      try {
        final node = state.getNodeAtPath([0, 0])!;
        final before = jsonEncode(state.document.toJson());
        state.selection = Selection.single(
          path: [0, 0],
          startOffset: 0,
          endOffset: node.delta!.length,
        );
        _editor(tester).commandShortcutEvents
            .singleWhere((event) => event.key == 'journal-cut')
            .handler(state);
        await tester.pump();
        expect(jsonEncode(state.document.toJson()), before);
        expect(find.text('剪切未删除原文，请重试'), findsOneWidget);
        expect(await tester.runAsync(journal.flush), isTrue);
        expect(store.saved!.documentJson, before);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester, journal);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      }
    },
  );
}
