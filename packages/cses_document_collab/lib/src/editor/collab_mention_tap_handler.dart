import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_inline_formula.dart';
import 'package:cses_document_collab/src/model/collab_mention_tap.dart';
import 'package:cses_document_collab/src/model/collab_user_mention.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';

/// 每个编辑器同时只运行一个提及点击；弱关联不延长编辑器生命周期。
final _pendingMentionTap = Expando<bool>('pendingMentionTap');

/// 处理借用 [context]/[state] 中 [node] 的UTF-16 [offset] 点击。
/// 有宿主回调时传递原始属性并等待完成，否则执行 [defaultAction] 展示现有面板。
/// 挂起期间同编辑器其他提及点击被忽略；预览允许调用，不写正文。
/// 关闭、失效节点或会话替换时不派发，异常向原宿主报告并在仍有效页面提示。
/// 完成后归还输入控制，已销毁或被新路由覆盖的页面不恢复键盘。
Future<void> handleCollabMentionTap(
  BuildContext context,
  EditorState state,
  Node node,
  int offset, {
  required Future<void> Function() defaultAction,
}) async {
  if (!context.mounted ||
      state.isDisposed ||
      _pendingMentionTap[state] == true) {
    return;
  }
  final services = CollabRuntime.services;
  _pendingMentionTap[state] = true;
  try {
    final blockId =
        node.attributes['cses_collab_block_id'] as String? ?? node.id;
    final current = findCollabInlineTextNode(state, blockId);
    if (current == null || offset < 0 || offset >= current.delta!.length) {
      return;
    }
    if (current.delta!.slice(offset, offset + 1) !=
        node.delta?.slice(offset, offset + 1)) {
      return;
    }
    await runEditorHeaderAction<void>(context, state, () async {
      if (!context.mounted ||
          state.isDisposed ||
          !identical(CollabRuntime.services, services)) {
        return;
      }
      final callback = services.onMentionTap;
      if (callback == null) {
        await defaultAction();
        return;
      }
      final operation = current.delta!.slice(offset, offset + 1).first;
      final attrs = operation.attributes;
      if (operation is! TextInsert ||
          operation.text != collabInlineFormulaCharacter) {
        return;
      }
      final kind = attrs?[collabMentionTypeAttribute] as String? ?? 'user';
      final type = CollabMentionType.values
          .where((v) => v.name == kind)
          .firstOrNull;
      final id = attrs?[collabMentionIdAttribute];
      final name = attrs?[collabInlineMentionAttribute];
      if (type == null || id is! String || id.isEmpty || name is! String) {
        return;
      }
      final raw = attrs?[collabMentionAttributesAttribute];
      if (raw is! String) {
        throw StateError('提及原始属性尚未就绪，请在投影确认后重试');
      }
      final original = jsonDecode(raw) as Map<String, dynamic>;
      await callback(
        CollabMentionTap(type: type, id: id, name: name, attributes: original),
      );
    }, canRestore: () => identical(CollabRuntime.services, services));
  } catch (error, stack) {
    services.report('提及点击操作失败', error, stack, 'DocCollab');
    if (context.mounted &&
        !state.isDisposed &&
        identical(CollabRuntime.services, services)) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
    }
  } finally {
    _pendingMentionTap[state] = null;
  }
}
