import 'package:cses_document_collab/src/model/editor_media_upload.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:cses_document_collab/src/ui/modal/editor_media_source_panel.dart';
import 'package:flutter/material.dart';

/// 在借用的 [context] 中展示媒体来源面板；[blockType] 为正文资源或document_banner/document_icon。
/// [initialValue] 默认空，预填链接；[allowRemove] 默认false，true允许返回空URL移除。
/// [canEdit] 是可选的提交时门禁，null不增加限制；[service] 借自宿主，null使用当前运行时端口。
/// Future等待面板完整退场后返回选中资源，取消为null；上传/校验失败留在面板中重试。
/// 不恢复正文焦点，调用方须用所属编辑器的操作会话隔离输入；Navigator错误透传。
Future<EditorMediaSource?> showEditorMediaSourceSheet(
  BuildContext context, {
  required String blockType,
  String initialValue = '',
  bool allowRemove = false,
  bool Function()? canEdit,
  EditorMediaUploadService? service,
}) async {
  final result = await showCollabBottomSheet<EditorMediaSource>(
    context: context,
    requestFocus: true,
    builder: (context) {
      return EditorMediaSourcePanel(
        kind: blockType,
        initialValue: initialValue,
        allowRemove: allowRemove,
        canEdit: canEdit,
        service: service ?? CollabRuntime.services.mediaUpload,
      );
    },
  );

  return result;
}
