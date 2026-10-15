import 'collab_document_feedback.dart';
import 'collab_task_card_data.dart';
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
  /// [onMentionTap] 接收用户直接点击、其他提及面板的打开详情及任务卡片详情；切换卡片不调用。
  /// 等待宿主详情关闭；行内提及恢复原输入，卡片不恢复正文键盘，包不创建用户资料界面。
  /// [pickMeetingReference] 由宿主选择或创建业务会议后返回引用；null时不提供新增入口。
  /// [loadMeetingCard] 加载会议本地详情及状态，null展示引用和未知状态，资源由宿主持有。
  /// [loadTaskCard] 加载任务本地详情，null仅展示共享标题；不拥有宿主网络资源。
  /// [onMeetingCardTap] 由卡片加入/查看按钮打开会议；null禁用该按钮，仍可删除引用。
  /// [documentMetadata] 提供正式头部的业务读写；草稿不使用该端口。
  /// [showDocumentFeedback] 默认false；true在正文末尾显示点赞和全文评论入口。
  /// [loadDocumentFeedback]加载当前文档的初始互动快照；null使用未点赞、空成员、0条评论。
  /// [onDocumentLike]接收文档ID和当前点赞快照，返回宿主确认的最新点赞快照；null禁用。
  /// [onDocumentComment]接收文档ID和当前评论数量，返回最新评论数量；null禁用。
  const CollabHostServices({
    this.showDocumentFeedback = false,
    this.loadDocumentFeedback,
    this.onDocumentLike,
    this.onDocumentComment,
    this.createId,
    this.onError,
    this.mediaUpload,
    this.documentMetadata,
    this.mentionAvatarBuilder,
    this.pickMentionUser,
    this.onMentionTap,
    this.onMeetingCardTap,
    this.loadMeetingCard,
    this.loadTaskCard,
    this.pickMeetingReference,
  });

  /// 是否显示整个文末点赞/全文评论区域，默认false；编辑和预览均适用。
  /// 配置随控制器生命周期固定；变更时由宿主重建控制器，不写入协同文档。
  final bool showDocumentFeedback;

  /// 加载[documentId]的初始点赞/评论快照；null使用空状态，不进行网络请求。
  /// 由宿主持有认证与请求，失败可重试；编辑器不释放宿主资源。
  final FutureOr<CollabDocumentFeedback> Function(String documentId)?
  loadDocumentFeedback;

  /// 点赞入口回调，[documentId]为稳定文档ID，[likes]包含点击前的完整成员和当前用户点赞状态。
  /// 宿主根据likes.isLiked执行点赞/取消，返回确认后的完整快照；返回null表示取消并保留原状态。
  /// 等待期间禁止重复操作，失败保留旧值并报告；业务鉴权、计数和持久化均由宿主负责。
  final FutureOr<CollabDocumentLikes?> Function(
    String documentId,
    CollabDocumentLikes likes,
  )?
  onDocumentLike;

  /// 全文评论入口回调，[documentId]为稳定文档ID，[commentCount]为当前非负评论数。
  /// 宿主等待评论页面关闭后返回最新非负数量；null保留原数量，负数作为失败处理。
  /// 点击收起正文键盘且不自动恢复；包不创建评论输入框或写入正文。
  final FutureOr<int?> Function(String documentId, int commentCount)?
  onDocumentComment;

  /// 借用宿主会议引用流程；宿主持有表单、选择/创建会议页面及业务资源。
  /// null不提供新增会议入口；包不构建默认会议表单，不创建业务会议。
  final CollabMeetingReferencePicker? pickMeetingReference;

  /// 可选任务卡片详情，业务标题/标签/人员/时间/统计仅本地展示。
  /// null保留共享标题且隐藏未知数据；明确缺失/失败禁用详情，失败可重试。
  final CollabTaskCardLoader? loadTaskCard;

  /// 可选会议详情加载器；宿主持有认证和请求，包只借用，不写协同文档。
  /// null展示共享引用及未知状态；不存在/失败禁用主按钮，失败可重试。
  final CollabMeetingCardLoader? loadMeetingCard;

  /// 可选会议卡片导航；[meetingId] 为稳定会议ID，[title] 为共享标题，[number] 为共享编号；后两者可为空。
  /// 仅加入/查看会议按钮触发，卡片其他区域不派发；返回直到详情关闭的Future，预览也可打开。
  /// 点击会关闭正文键盘，回调结束后不自动恢复输入焦点；业务鉴权和会议状态由宿主处理。
  final FutureOr<void> Function(String meetingId, String title, String number)?
  onMeetingCardTap;

  /// 可选统一提及点击处理，宿主持有其路由/业务资源；预览可调用，异常由编辑器报告。
  /// 用户未配置时不响应；其他提及点击先显示操作面板，只有打开详情调用此回调。
  /// null禁用详情操作，编辑时仍可切换卡片或删除引用；任务卡片详情传共享引用props。
  final CollabMentionTapCallback? onMentionTap;

  /// 可选宿主头像构建器，用于正文用户提及和任务负责人；null正文只显示姓名，任务隐藏头像组。
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
