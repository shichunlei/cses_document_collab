import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_user_mention.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';

/// 在借用 [context] 中构建宿主头像槽；[userId]/[name] 为当前位置的人员，
/// [size] 为正逻辑像素边长，[avatarUrl] 可为空；无构建器返回null，不创建默认头像。
Widget? buildHostMentionAvatarSlot(
  BuildContext context, {
  required String userId,
  required String name,
  required double size,
  String? avatarUrl,
}) {
  final builder = CollabRuntime.services.mentionAvatarBuilder;
  if (builder == null) return null;
  return ExcludeSemantics(
    child: SizedBox.square(
      dimension: size,
      child: builder(
        context,
        userId: userId,
        name: name,
        size: size,
        avatarUrl: avatarUrl,
      ),
    ),
  );
}

/// 防止同编辑器同时打开多个宿主选择界面；不强持有已释放编辑器。
final _picking = Expando<bool>('host-mention-picker');

/// 借用 [context]/[editor] 调用宿主选人，[keyword] 为初始搜索词，默认空。
/// 不构建选择界面；等待宿主退场后校验会话、权限及页面，取消/失效返回null。
/// 借出的权限信号由本函数创建/释放，权限一旦撤销即使恢复也拒绝此次结果；异常透传调用方。
Future<CollabMentionUser?> pickHostMentionUser(
  BuildContext context,
  EditorState editor, {
  String keyword = '',
}) async {
  final services = CollabRuntime.services;
  final picker = services.pickMentionUser;
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
    final user = await picker(context, keyword: keyword, canEdit: canEdit);
    if (!context.mounted ||
        editor.isDisposed ||
        !editor.editable ||
        !canEdit.value ||
        !identical(CollabRuntime.services, services)) {
      return null;
    }
    return user;
  } finally {
    editor.editableNotifier.removeListener(permissionChanged);
    editor.onDispose.removeListener(permissionChanged);
    canEdit.dispose();
    _picking[editor] = false;
  }
}
