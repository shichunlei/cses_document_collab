import 'collab_user_mention.dart';
import 'dart:math';
import 'collab_mention_tap.dart';
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
  /// [mentionDirectory] 提供当前企业人员查询；null禁用新增，已有提及仍可展示/删除。
  /// [onMentionTap] 可接管四类提及点击；null使用内置面板，等待宿主详情关闭后恢复输入。
  /// [documentMetadata] 提供正式头部的业务读写；草稿不使用该端口。
  const CollabHostServices({
    this.createId,
    this.onError,
    this.mediaUpload,
    this.documentMetadata,
    this.mentionDirectory,
    this.onMentionTap,
  });

  /// 可选统一提及点击处理，宿主持有其路由/业务资源；预览可调用，异常由编辑器报告。
  /// null保留用户资料和实体信息面板；配置后替代面板，不改变正文。
  final CollabMentionTapCallback? onMentionTap;

  /// 借用的人员查询端口；宿主持有认证与资源，编辑器不关闭它。
  final CollabMentionDirectory? mentionDirectory;

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
