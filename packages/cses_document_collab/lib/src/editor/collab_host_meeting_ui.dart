import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_meeting_reference.dart';
import 'package:flutter/material.dart';

/// 防止同编辑器同时打开多个宿主会议页面；不强持有已释放编辑器。
final _picking = Expando<bool>('host-meeting-picker');

/// 借用 [context]/[editor] 调用宿主会议选择/创建页面。
/// 不构建宿主页面；等待宿主退场后校验会话、权限及页面，取消/失效返回null。
/// 借出的权限信号由本函数创建/释放，权限一旦撤销即使恢复也拒绝此次结果；异常透传调用方。
Future<CollabMeetingReference?> pickHostMeetingReference(
  BuildContext context,
  EditorState editor,
) async {
  final services = EditorCommandContext.of(editor).services;
  final picker = services.pickMeetingReference;
  if (picker == null ||
      !context.mounted ||
      editor.isDisposed ||
      !editor.editable ||
      _picking[editor] == true) {
    return null;
  }
  final canEdit = ValueNotifier<bool>(true);

  /// 权限撤销永久作废此次选择，宿主不得确认旧结果。
  void permissionChanged() {
    if (!editor.editable || editor.isDisposed) canEdit.value = false;
  }

  _picking[editor] = true;
  editor.editableNotifier.addListener(permissionChanged);
  editor.onDispose.addListener(permissionChanged);
  try {
    final reference = await picker(context, canEdit: canEdit);
    if (!context.mounted ||
        editor.isDisposed ||
        !editor.editable ||
        !canEdit.value ||
        !identical(EditorCommandContext.of(editor).services, services)) {
      return null;
    }
    return reference;
  } finally {
    editor.editableNotifier.removeListener(permissionChanged);
    editor.onDispose.removeListener(permissionChanged);
    canEdit.dispose();
    _picking[editor] = false;
  }
}
