import 'package:cses_document_collab/src/model/collab_document_feedback.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:flutter/foundation.dart';

/// 单文档文末互动状态，跨编辑/预览切换保存，串行处理宿主读写。
/// 创建者负责关闭；借用的宿主资源不释放，关闭会等待已发出的回调。
///
/// 宿主通过所属协同控制器使用：
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final collab = CollabController.localDraft(databasePath: '/host/updates.sqlite');
/// await collab.feedback.ensureLoaded();
/// // 页面结束后 await collab.close()，一并释放互动状态。
/// ```
class DocumentFeedbackController extends ChangeNotifier {
  /// [documentId]是固定文档ID，[services]为借用的宿主端口，不跨文档/账号复用。
  DocumentFeedbackController({required this.documentId, required this.services});

  /// 固定文档ID，所有宿主回调都使用此身份。
  final String documentId;

  /// 借用的宿主读写与错误端口；不关闭宿主资源。
  final CollabHostServices services;

  /// 最近宿主确认的快照，未加载时为空；不参与正文投影。
  CollabDocumentFeedback _value = CollabDocumentFeedback(likes: CollabDocumentLikes());

  /// 只有首次成功读取后才允许以加载数据发起业务写入。
  bool _loaded = false;
  bool _busy = false;
  bool _disposed = false;
  String? _error;

  /// 唯一进行中的宿主任务；关闭须等待，完成后清除引用。
  Future<void>? _operation;

  /// 最近确认的业务快照；初始无加载器时使用空状态。
  CollabDocumentFeedback get value => _value;

  /// 当前是否等待宿主读取、点赞或评论回调。
  bool get busy => _busy;

  /// 初始状态是否可用；加载失败时禁止基于未知状态发送点赞/评论。
  bool get ready => !_disposed && (services.loadDocumentFeedback == null || _loaded);

  /// 最近失败提示，成功或开始新操作时清空；供文末区显示重试。
  String? get error => _error;

  /// 只在初始数据未知时加载；并发调用共享当前任务，失败后可重试。
  Future<void> ensureLoaded() {
    if (ready || _disposed) return Future.value();
    return refresh();
  }

  /// 刷新当前文档的宿主快照；忙碌时等待已有操作，不与写入交错。
  Future<void> refresh() {
    final loader = services.loadDocumentFeedback;
    if (_disposed || loader == null) return Future.value();
    return _run(() async {
      final next = await loader(documentId);
      if (!_disposed) _loaded = true;
      return next;
    });
  }

  /// 把当前点赞成员及用户状态交给宿主，确认后更新；null结果保留原值。
  Future<void> toggleLike() {
    final callback = services.onDocumentLike;
    if (!ready || callback == null) return Future.value();
    return _run(() async {
      final likes = await callback(documentId, _value.likes);
      return likes == null ? null : CollabDocumentFeedback(likes: likes, commentCount: _value.commentCount);
    });
  }

  /// 把当前评论数交给宿主，等待评论界面关闭并更新数量；null保留原值。
  Future<void> openComments() {
    final callback = services.onDocumentComment;
    if (!ready || callback == null) return Future.value();
    return _run(() async {
      final count = await callback(documentId, _value.commentCount);
      return count == null ? null : CollabDocumentFeedback(likes: _value.likes, commentCount: count);
    });
  }

  /// 串行执行[action]，确认后更新快照；失败保留旧值并报告，不抛到UI事件循环。
  Future<void> _run(Future<CollabDocumentFeedback?> Function() action) {
    if (_disposed) return Future.value();
    if (_busy) return _operation ?? Future.value();
    _busy = true;
    _error = null;
    // 先记录任务，再通知监听者，避免监听期间重复发起宿主请求。
    final task = Future<void>.microtask(() async {
      try {
        if (_disposed) return;
        final next = await action();
        if (!_disposed && next != null) _value = next;
      } catch (error, stack) {
        services.report('文末互动操作失败', error, stack, 'DocumentFeedback');
        if (!_disposed) _error = '操作失败，请重试';
      } finally {
        _busy = false;
        _operation = null;
        if (!_disposed) notifyListeners();
      }
    });
    _operation = task;
    notifyListeners();
    return task;
  }

  /// 立即使后续结果失效；重复释放忽略，不释放借用端口。
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }

  /// 使结果失效并等待仍在使用宿主资源的操作；重复关闭等待同一任务。
  Future<void> close() async {
    dispose();
    final pending = _operation;
    if (pending != null) await pending;
  }
}
