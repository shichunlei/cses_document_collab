import 'collab_meeting_card_data.dart';
import 'collab_meeting_reference.dart';
import 'dart:async';
import 'dart:math';
import 'collab_mention_tap.dart';
import 'collab_mention_ui.dart';
import 'document_metadata.dart';

import 'package:cses_document_collab/src/model/editor_media_upload.dart';
import 'package:flutter/foundation.dart';

/// Reports an unexpected failure with its original error and stack trace.
typedef CollabErrorReporter =
    void Function(
      String message,
      Object error,
      StackTrace stackTrace,
      String? tag,
    );

/// Host integrations used by the single active document, without session globals.
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// const services = CollabHostServices();
/// // 将services注入由宿主持有的CollabController。
/// ```
/// Optional media upload enables the local-file tab; URL editing is always usable.
class CollabHostServices {
  /// [createId] generates unique block/session IDs; null uses secure 24-digit
  /// hexadecimal IDs. [onError] reports failures; null prints error and stack.
  /// [mediaUpload] is borrowed and must use the host's current authentication.
  /// [mentionAvatarBuilder] 由宿主构建头像；null仅显示姓名，无默认头像或图片请求。
  /// [pickMentionUser] 由宿主打开单选人员界面；null禁用选人，已有提及不受影响。
  /// [onMentionTap] 接收四类提及点击；用户未配置时不响应，其他实体保留默认面板。
  /// 配置后等待宿主详情关闭再恢复输入，包不创建用户资料界面。
  /// [pickMeetingReference] 由宿主选择或创建业务会议后返回引用；null时不提供新增入口。
  /// [loadMeetingCard] 加载会议本地详情及状态，null展示引用和未知状态，资源由宿主持有。
  /// [onMeetingCardTap] 由卡片加入/查看按钮打开会议；null禁用该按钮，仍可删除引用。
  /// [documentMetadata] 提供正式头部的业务读写；草稿不使用该端口。
  const CollabHostServices({
    this.createId,
    this.onError,
    this.mediaUpload,
    this.documentMetadata,
    this.mentionAvatarBuilder,
    this.pickMentionUser,
    this.onMentionTap,
    this.onMeetingCardTap,
    this.loadMeetingCard,
    this.pickMeetingReference,
  });

  /// 借用宿主会议引用流程；宿主持有表单、选择/创建会议页面及业务资源。
  /// null不提供新增会议入口；包不构建默认会议表单，不创建业务会议。
  final CollabMeetingReferencePicker? pickMeetingReference;

  /// 可选会议详情加载器；宿主持有认证和请求，包只借用，不写协同文档。
  /// null展示共享引用及未知状态；不存在/失败禁用主按钮，失败可重试。
  final CollabMeetingCardLoader? loadMeetingCard;

  /// 可选会议卡片导航；[meetingId] 为稳定会议ID，[title] 为共享标题，[number] 为共享编号；后两者可为空。
  /// 仅加入/查看会议按钮触发，卡片其他区域不派发；返回直到详情关闭的Future，预览也可打开。
  /// 点击会关闭正文键盘，回调结束后不自动恢复输入焦点；业务鉴权和会议状态由宿主处理。
  final FutureOr<void> Function(String meetingId, String title, String number)?
  onMeetingCardTap;

  /// 可选统一提及点击处理，宿主持有其路由/业务资源；预览可调用，异常由编辑器报告。
  /// 用户未配置时不响应；会议/任务/文档未配置时保留实体信息面板，不改变正文。
  final CollabMentionTapCallback? onMentionTap;

  /// 可选宿主头像构建器，用于正文用户提及；null只显示姓名。
  /// 头像加载、缓存和占位由宿主负责，编辑器只约束尺寸，不写正文。
  final CollabMentionAvatarBuilder? mentionAvatarBuilder;

  /// 可选宿主单选人员入口；null不打开人员选择界面，输入@仍是普通文字。
  /// 等待宿主界面退场再校验并插入，权限、位置或会话失效时丢弃结果。
  final CollabMentionUserPicker? pickMentionUser;

  /// 正式文档头部业务接口；null 时宿主不提供头部能力。
  final DocumentMetadataService? documentMetadata;

  /// Host ID generator, borrowed for the lifetime of the document.
  final String Function()? createId;

  /// Host telemetry callback; never receives credentials from the package.
  final CollabErrorReporter? onError;

  /// Authenticated picker/upload integration; null disables local upload.
  final EditorMediaUploadService? mediaUpload;

  /// Generate a unique ID; the host is responsible for custom factory uniqueness.
  String newId() =>
      createId?.call() ??
      List.generate(
        12,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();

  /// Forward [message], [error], [stackTrace] and [tag] to the host logger.
  /// Without a logger, retain the full failure in Flutter diagnostic output.
  void report(
    String message,
    Object error,
    StackTrace stackTrace,
    String? tag,
  ) {
    if (onError case final report?) {
      report(message, error, stackTrace, tag);
    } else {
      debugPrint('$tag: $message: $error\n$stackTrace');
    }
  }
}
