import 'dart:async';
import 'package:cses_document_collab/cses_document_collab.dart' show PreparedDocument;
import 'package:flutter/foundation.dart';
import 'document_creation_api.dart';
import 'document_creation_operation.dart';
import 'document_creation_store.dart';

/// 串行编排一个账号的新建及已有文档打开；记录先于建档写入，迟到结果归原账号。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_coordinator.dart';
/// Future<void> resume(DocumentCreationCoordinator coordinator) async {
///   await coordinator.restore();
///   if (coordinator.operation != null) await coordinator.resume();
///   await coordinator.close();
/// }
/// ```
final class DocumentCreationCoordinator extends ChangeNotifier {
  /// 借用[_api]与[_store]；[_createId]每次生成唯一操作/段落ID。
  /// [_prepare]只准备已建档正文，[_closeDocument]等待旧文档释放且保留主连接，
  /// [_openDocument]打开正式ID。回调的资源由宿主持有；close等待在途任务。
  DocumentCreationCoordinator({
    required this._api,
    required this._store,
    required this._createId,
    required this._prepare,
    required this._closeDocument,
    required this._openDocument,
  });
  final DocumentCreationApi _api;
  final DocumentCreationStore _store;
  final String Function() _createId;
  final Future<PreparedDocument> Function(DocumentCreationOperation) _prepare;
  final Future<void> Function() _closeDocument;
  final Future<void> Function(String) _openDocument;

  /// 最新已知结果；落盘失败也保留已取得的正式ID，继续时先补写记录。
  DocumentCreationOperation? _operation;

  /// 唯一在途文档操作，创建重复调用共享结果，普通打开在忙碌时拒绝；close负责等待。
  Future<String?>? _task;

  /// 普通打开占锁时不向创建/恢复调用者返回另一份文档的结果。
  bool _openingExisting = false;

  /// 仅保留在途恢复任务供并发调用共享；结束后清除，不能与创建任务交错覆盖记录。
  Future<void>? _restoration;
  bool _closed = false;

  /// 仅成功读取恢复记录后才允许建档，损坏记录不得被新操作覆盖。
  bool _restored = false;
  String? _error;

  /// 当前账号最近操作，包含可恢复的正式ID。
  DocumentCreationOperation? get operation => _operation;

  /// 在途操作期间禁止重复提交、切换位置及清缓存。
  bool get busy => _task != null;

  /// 可展示的失败，不包含网络请求或身份凭证。
  String? get error => _error;

  /// 已知操作是否尚未完成，结果不明也保留入口供核对。
  bool get pending =>
      _operation != null &&
      ![
        DocumentCreationStage.completed,
        DocumentCreationStage.rejected,
        DocumentCreationStage.reviewed,
      ].contains(_operation!.stage);

  /// 未知建档结果只能由用户核对后结束，不能通过继续按钮自动重发。
  bool get needsReview => _operation?.stage == DocumentCreationStage.createUnknown;

  /// 读取恢复记录；并发调用共享结果，创建期间拒绝重读。
  /// 创建请求在途时退出会转换为结果不明，不自动重发；失败后允许再次读取。
  Future<void> restore() {
    try {
      _ensureActive();
    } catch (error, stack) {
      return Future<void>.error(error, stack);
    }
    if (busy) return Future<void>.error(StateError('创建期间不能重新读取恢复记录'));
    if (_restored) return Future<void>.value();
    return _restoration ??= _restoreRecoverably();
  }

  /// 失败后解除恢复任务缓存，使文件系统恢复后可以重新尝试。
  Future<void> _restoreRecoverably() async {
    try {
      await _restoreOnce();
    } finally {
      _restoration = null;
    }
  }

  /// 安装一次稳定恢复快照；start在读取成功前禁止发送建档请求。
  Future<void> _restoreOnce() async {
    _ensureActive();
    final stored = await _store.read();
    _ensureActive();
    _operation = stored;
    if (stored?.stage == DocumentCreationStage.creating) {
      await _save(stored!.advance(DocumentCreationStage.createUnknown));
    }
    _restored = true;
    _notify();
  }

  /// 在[target]下开始新建；重复调用共享在途任务，未完成操作要求先恢复。
  Future<String?> start(DocumentCreationTarget target) => _execute(() async {
    if (!_restored) throw const FormatException('创建记录尚未成功读取，请重新打开页面');
    if (pending) throw const FormatException('请先处理上次未完成的创建');
    await _api.verifyTarget(target);
    _ensureActive();
    await _persistThenInstall(
      DocumentCreationOperation(
        operationId: _createId(),
        paragraphId: _createId(),
        createdAt: DateTime.now().millisecondsSinceEpoch,
        target: target,
      ),
    );
    _ensureActive();
    String id;
    try {
      id = await _api.createBlank(target);
    } on DocumentCreationRejected {
      await _save(_operation!.advance(DocumentCreationStage.rejected));
      rethrow;
    } catch (_) {
      await _save(_operation!.advance(DocumentCreationStage.createUnknown));
      rethrow;
    }
    // 即使页面已退出或账号改变，也先把成功ID保存到原账号分区。
    await _save(_operation!.advance(DocumentCreationStage.shellCreated, documentId: id));
    _ensureActive();
    return _continue();
  });

  /// 继续已知docId的操作；未知建档结果停止自动重试，快照结果不明先回读。
  Future<String?> resume() => _execute(() async {
    final operation = _operation;
    if (operation == null || operation.documentId == null) {
      throw const FormatException('建档结果不明，请先在文档库核对，不能再次自动创建');
    }
    return _continue();
  });

  /// 普通打开[documentId]并返回同一ID；忙碌、失败或关闭时返回null。
  /// 先核验访问，再释放旧文档、打开正式控制器。沿用同一操作锁和账号检查，
  /// 不建档、不准备正文，也不改变已有创建恢复记录；失败由error展示。
  /// [reuseCurrentDocument]仅供宿主确认同一控制器已初始化时设true，保留其历史；仍重新读取详情核验类型与访问。
  /// 复用仍核对账号并占用操作锁，同时清除上次打开失败的提示。
  Future<String?> openExistingDocument(String documentId, {bool reuseCurrentDocument = false}) {
    if (busy) return Future<String?>.value();
    return _execute(
      () async {
        if (!_restored) throw const FormatException('文档服务尚未恢复，请重试');
        if (documentId.trim().isEmpty || documentId.length > 128) {
          throw const FormatException('请选择有效文档');
        }
        await _api.verifyDocumentToOpen(documentId);
        _ensureActive();
        if (reuseCurrentDocument) return documentId;
        await _closeDocument();
        _ensureActive();
        await _openDocument(documentId);
        _ensureActive();
        return documentId;
      },
      failureMessage: '文档打开失败，请重试',
      openingExisting: true,
    );
  }

  /// 用户核对文档库后结束[operationId]对应的未知操作，成功返回true。
  /// 先持久化reviewed再解除挂起；失败保留原记录。只结束本地跟踪，不发建档、
  /// 正文或删除请求。旧页面ID、账号变化及在途创建均不能结束另一项操作。
  Future<bool> finishReviewedOperation(String operationId) async {
    if (busy) return false;
    final result = await _execute(() async {
      final operation = _operation;
      if (!_restored ||
          !needsReview ||
          operation?.operationId != operationId ||
          operation?.documentId != null) {
        throw const FormatException('创建记录已变化，请重新核对');
      }
      await _persistThenInstall(operation!.advance(DocumentCreationStage.reviewed));
      return operationId;
    });
    return result == operationId;
  }

  /// 串行推进已记录操作；打开前的HTTP与本地正文始终使用同一快照。
  Future<String> _continue() async {
    _ensureActive();
    await _store.write(_operation!);
    _ensureActive();
    if (_operation!.stage == DocumentCreationStage.shellCreated) {
      await _closeDocument();
      _ensureActive();
      final prepared = await _prepare(_operation!);
      _ensureActive();
      if (prepared.documentId != _operation!.documentId ||
          prepared.paragraphId != _operation!.paragraphId) {
        throw const FormatException('初始化正文身份不匹配');
      }
      await _save(
        _operation!.advance(
          DocumentCreationStage.bodyPrepared,
          snapshotJson: prepared.snapshotJson,
        ),
      );
    }
    _ensureActive();
    final stage = _operation!.stage;
    if (stage == DocumentCreationStage.snapshotSending ||
        stage == DocumentCreationStage.bodyPrepared) {
      final prepared = PreparedDocument.fromSnapshotJson(_operation!.snapshotJson ?? '');
      if (prepared.documentId != _operation!.documentId ||
          prepared.paragraphId != _operation!.paragraphId) {
        throw const FormatException('恢复快照身份不匹配');
      }
      if (stage == DocumentCreationStage.snapshotSending) {
        final state = await _api.readInitial(prepared);
        _ensureActive();
        if (state != InitialSnapshotState.matches) {
          throw FormatException(
            state == InitialSnapshotState.missing
                ? '初始快照结果待确认，请稍后重新核对；不会重复写入'
                : '服务端已有不同正文，请在文档库恢复；未覆盖内容',
          );
        }
      } else {
        await _save(_operation!.advance(DocumentCreationStage.snapshotSending));
        _ensureActive();
        try {
          await _api.writeInitial(prepared);
        } on DocumentCreationRejected {
          await _save(_operation!.advance(DocumentCreationStage.bodyPrepared));
          rethrow;
        }
        _ensureActive();
      }
      await _save(_operation!.advance(DocumentCreationStage.snapshotAccepted));
    }
    _ensureActive();
    if (![
      DocumentCreationStage.snapshotAccepted,
      DocumentCreationStage.completed,
    ].contains(_operation!.stage)) {
      throw const FormatException('创建阶段不完整，请核对恢复记录');
    }
    await _closeDocument();
    _ensureActive();
    await _openDocument(_operation!.documentId!);
    _ensureActive();
    await _save(_operation!.advance(DocumentCreationStage.completed));
    return _operation!.documentId!;
  }

  /// 排队执行[run]，在任何同步失败前安装唯一任务；重复创建共享结果，普通打开期间拒绝其他操作。
  /// 失败映射为固定展示消息，已知阶段继续留在存储供恢复。
  /// [failureMessage]为非业务/格式错误的固定提示，null按当前创建阶段选择文案。
  /// [openingExisting]为true时锁定普通打开，期间其他操作返回null而不共享该文档ID。
  Future<String?> _execute(
    Future<String> Function() run, {
    String? failureMessage,
    bool openingExisting = false,
  }) {
    if (_task != null) return _openingExisting ? Future<String?>.value() : _task!;
    _error = null;
    _openingExisting = openingExisting;
    final task = _task = Future<String?>(() async {
      try {
        _ensureActive();
        return await run();
      } catch (failure) {
        _error = failure is DocumentCreationRejected
            ? failure.message
            : failure is FormatException
            ? failure.message
            : failureMessage ??
                  (_operation?.stage == DocumentCreationStage.createUnknown
                      ? '创建结果不明，请先在文档库核对，避免重复建档'
                      : '创建未完成，请重试或继续完成已有文档');
        return null;
      } finally {
        _task = null;
        _openingExisting = false;
        _notify();
      }
    });
    _notify();
    return task;
  }

  /// 持久化[next]后才安装不会发出外部写入的新意图或人工结束结果。
  /// 失败保留先前内存状态，不阻塞尚未发送的创建，也不提前解除挂起。
  Future<void> _persistThenInstall(DocumentCreationOperation next) async {
    await _store.write(next);
    _operation = next;
    _notify();
  }

  /// 保留[next]的已知结果并等待落盘后通知页面；关闭后仍允许记录已发请求的返回结果。
  Future<void> _save(DocumentCreationOperation next) async {
    _operation = next;
    await _store.write(next);
    _notify();
  }

  /// 异步间隔后核对协调器及绑定账号，禁止旧操作继续发请求或导航。
  void _ensureActive() {
    if (_closed) throw StateError('创建页面已关闭');
    _api.checkSession();
  }

  /// 只向仍借用本协调器的页面发通知。
  void _notify() {
    if (!_closed) notifyListeners();
  }

  /// 同步使操作失效；在途结果仅允许保存原账号恢复信息。
  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    super.dispose();
  }

  /// 停止后续操作并等待已发送请求及记录写入；重复调用安全。
  Future<void> close() async {
    dispose();
    await _restoration?.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    await _task;
  }
}
