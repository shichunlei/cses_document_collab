import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/controller/document_feedback_controller.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 编辑器内部文末互动区，借用控制器保存点赞/评论状态，业务行为归宿主所有。
/// 底部留20个逻辑像素，系统安全区和正文最小视口高度由外层页面负责。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final controller = CollabController.localDraft(
///   databasePath: '/host/updates.sqlite',
///   services: CollabHostServices(
///     showDocumentFeedback: true,
///     onDocumentLike: (id, likes) async => null, // 返回宿主确认的点赞快照。
///     onDocumentComment: (id, count) async => count,
///   ),
/// );
/// final page = CollaborativeEditorPage(collab: controller);
/// // 路由退出后由宿主 await controller.close()。
/// ```
class DocumentFeedbackFooter extends StatefulWidget {
  /// [controller]为所属文档的互动状态，[editorState]用于关闭正文键盘，均由调用方持有/释放。
  /// [enabled]默认true，false暂停点击；[key]控制组件身份与状态复用。
  const DocumentFeedbackFooter({super.key, required this.controller, required this.editorState, this.enabled = true});

  /// 必填借用的文档互动控制器，切换模式或滚动重建不会丢失状态。
  final DocumentFeedbackController controller;

  /// 必填借用的正文状态；点击时关闭其键盘且不自动恢复焦点。
  final EditorState editorState;

  /// 是否允许点击，默认true；由页面在导入等互斥流程中设为false。
  final bool enabled;

  /// 创建初始加载生命周期，不持有宿主业务资源。
  @override
  createState() => _DocumentFeedbackFooterState();
}

/// 仅负责挂接互动状态与输入边界，不在视图中保留业务快照。
class _DocumentFeedbackFooterState extends State<DocumentFeedbackFooter> {
  /// 初次挂载加载宿主数据，控制器捕获失败并提供重试状态。
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.ensureLoaded());
  }

  /// [oldWidget]的文档控制器变化时加载新文档；旧任务由其所有者管理关闭。
  @override
  void didUpdateWidget(covariant DocumentFeedbackFooter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      unawaited(widget.controller.ensureLoaded());
    }
  }

  /// 收起正文键盘并等待[action]；未启用、正文已关闭或已有任务时忽略点击。
  /// action由控制器捕获宿主异常，完成后不恢复正文输入或更新已卸载视图。
  Future<void> _invoke(Future<void> Function() action) async {
    if (!widget.enabled || widget.controller.busy || widget.editorState.isDisposed) {
      return;
    }
    widget.editorState.service.keyboardService?.closeKeyboard();
    FocusManager.instance.primaryFocus?.unfocus();
    await action();
  }

  /// 在[context]主题中订阅当前业务状态，仅重建文末区。
  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: widget.controller, builder: (context, _) => _buildContent(context));

  /// 在[context]主题中渲染圆形点赞按钮、居中提示和全文评论按钮，不构建输入框。
  Widget _buildContent(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final controller = widget.controller;
    final services = controller.services;
    final feedback = controller.value;
    final likes = feedback.likes;
    final available = widget.enabled && !controller.busy && controller.ready;
    final likeColor = likes.isLiked ? const Color(0xFFFFC928) : colors.primary;
    return Padding(
      key: const ValueKey('document-feedback-footer'),
      padding: const EdgeInsets.fromLTRB(20, 48, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: IconButton.outlined(
              key: const ValueKey('document-like'),
              tooltip: likes.isLiked ? '取消点赞' : '点赞',
              onPressed: available && services.onDocumentLike != null
                  ? () async => await _invoke(controller.toggleLike)
                  : null,
              style: IconButton.styleFrom(
                foregroundColor: likes.isLiked ? Colors.white : colors.primary,
                backgroundColor: likes.isLiked ? likeColor : null,
                disabledForegroundColor: likes.isLiked ? Colors.white : null,
                disabledBackgroundColor: likes.isLiked ? likeColor : null,
                side: BorderSide(color: likeColor),
                fixedSize: const Size(64, 64),
              ),
              icon: const Icon(LucideIcons.thumbsUp, size: 28),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(width: 36, child: Divider()),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    likes.isLiked ? '你已赞' : '真诚点赞，手留余香',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ),
              ),
              const SizedBox(width: 36, child: Divider()),
            ],
          ),
          if (likes.members.isNotEmpty) ...[
            const SizedBox(height: 16),
            Wrap(
              key: const ValueKey('document-like-members'),
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final member in likes.members.take(10))
                  Semantics(
                    label: '${member.name.isEmpty ? '成员' : member.name}已点赞',
                    child: Tooltip(
                      message: member.name.isEmpty ? '成员' : member.name,
                      child: ExcludeSemantics(
                        child: SizedBox(
                          width: 28,
                          height: 28,
                          child:
                              services.mentionAvatarBuilder?.call(
                                context,
                                userId: member.userId,
                                name: member.name,
                                size: 28,
                                avatarUrl: member.avatarUrl,
                              ) ??
                              CircleAvatar(child: Text(member.name.isEmpty ? '?' : member.name.characters.first)),
                        ),
                      ),
                    ),
                  ),
                if (likes.members.length > 10)
                  SizedBox(height: 28, child: Center(child: Text('+${likes.members.length - 10}人'))),
              ],
            ),
          ],
          if (controller.busy) ...[
            const SizedBox(height: 16),
            const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
          ],
          if (controller.error != null) ...[
            const SizedBox(height: 12),
            Text(controller.error!, textAlign: TextAlign.center),
            if (!controller.ready)
              TextButton(
                onPressed: widget.enabled && !controller.busy ? () async => await _invoke(controller.refresh) : null,
                child: const Text('重新加载'),
              ),
          ],
          const SizedBox(height: 32),
          OutlinedButton(
            key: const ValueKey('document-comment'),
            onPressed: available && services.onDocumentComment != null
                ? () async => await _invoke(controller.openComments)
                : null,
            style: OutlinedButton.styleFrom(
              alignment: Alignment.centerLeft,
              foregroundColor: colors.onSurfaceVariant,
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              side: BorderSide(color: colors.outlineVariant),
            ),
            child: Text(feedback.commentCount == 0 ? '评论全文…' : '评论全文（${feedback.commentCount}）'),
          ),
        ],
      ),
    );
  }
}
