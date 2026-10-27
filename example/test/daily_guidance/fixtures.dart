import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_store.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_controller.dart';

/// 创建明确已添加三个栏目的[now]草稿，供迁移前已有几何/边界回归继续验证相同内容。
JournalDraft threeSectionDraft(DateTime now) {
  final blank = JournalDraft.blank(now);
  final document = Document(
    root: Node(
      type: 'page',
      children: [
        for (final kind in journalSections)
          Node(
            type: journalSectionType,
            attributes: {'section': kind},
            children: [paragraphNode()],
          ),
      ],
    ),
  );
  try {
    return JournalDraft(
      id: blank.id,
      date: blank.date,
      createdAt: blank.createdAt,
      updatedAt: blank.updatedAt,
      timezoneOffsetMinutes: blank.timezoneOffsetMinutes,
      documentJson: jsonEncode(document.toJson()),
    );
  } finally {
    document.dispose();
  }
}

/// 打开借用[store]的测试会话并显式添加可选栏目；[now]/[saveDelay]透传生产控制器。
/// 清除初始化命令历史，使已有正文回归只观察其自身操作；调用者仍须close。
Future<LocalJournalController> openTestJournal({
  required JournalStore store,
  DateTime? now,
  Duration saveDelay = const Duration(milliseconds: 500),
}) async {
  final journal = await LocalJournalController.open(
    store: store,
    now: now,
    saveDelay: saveDelay,
  );
  await journal.addSection('reflection');
  await journal.addSection('self-check');
  journal.editor.editorState.undoManager.undoStack.clear();
  journal.editor.editorState.undoManager.redoStack.clear();
  return journal;
}
