import 'dart:async';
import 'package:flutter/material.dart';
import 'document_creation_coordinator.dart';
import 'document_creation_operation.dart';
import 'document_list_page.dart';
import 'document_space_list.dart';

/// 展示空间文档列表并提供新建入口的宿主页面，借用协调器和打开回调。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_page.dart';
/// import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_coordinator.dart';
/// import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_operation.dart';
/// import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_list_page.dart';
/// Widget creationPage(DocumentCreationCoordinator coordinator,
///     Future<List<DocumentCreationTarget>> Function() load, DocumentPageLoader documents) =>
///   DocumentCreationPage(coordinator: coordinator, loadTargets: load, loadDocuments: documents);
/// ```
class DocumentCreationPage extends StatefulWidget {
  /// [key]控制路由内状态复用，[coordinator]由宿主持有，[loadTargets]提供真实位置，
  /// [loadDocuments]读取该位置的分页文档。创建入口固定在右上角。
  /// [onOpenDocument]打开条目并展示编辑页，Future在编辑页退出后完成；null时仅展示列表。
  /// [initialTarget]非null时继承入口位置；创建成功后交给打开回调，未配置回调时返回正式ID。
  const DocumentCreationPage({
    super.key,
    required this.coordinator,
    required this.loadTargets,
    required this.loadDocuments,
    this.onOpenDocument,
    this.initialTarget,
  });

  /// 借用的新建协调器，页面卸载不释放它。
  final DocumentCreationCoordinator coordinator;

  /// 宿主位置读取函数，失败显示重试，不生成默认假ID。
  final Future<List<DocumentCreationTarget>> Function() loadTargets;

  /// 宿主文档分页读取函数；位置切换时刷新，失败显示重试，不影响独立创建命令。
  final DocumentPageLoader loadDocuments;

  /// 借用的文档打开/导航回调，也用于新建成功的文档；失败抛异常，留在列表允许重试。
  /// 宿主拥有控制器，回调负责有效路由检查，返回列表后本页保留原空间与滚动状态。
  final Future<void> Function(String documentId)? onOpenDocument;

  /// 入口传入的空间或文件夹，默认选择真实列表首项。
  final DocumentCreationTarget? initialTarget;

  /// 创建只持有位置及按钮状态的页面状态。
  @override
  createState() => _DocumentCreationPageState();
}

/// 管理位置异步读取；创建结果归协调器记录，离开路由不取消已发送的建档请求。
class _DocumentCreationPageState extends State<DocumentCreationPage> {
  List<DocumentCreationTarget> _targets = [];

  /// 当前选择及本页恢复操作的固定位置；完成待导航时不被迟到空间选项覆盖。
  DocumentCreationTarget? _selected;
  bool _loading = true;

  /// 同时充当在途门禁与回写令牌；页面退出时失效，不取消借用的宿主请求。
  Object? _positionRequest;

  /// 路由内即时防重复；实际任务归宿主协调器，离开路由后仍保留进度。
  bool _running = false;

  /// 成功时路由若被覆盖，保留结果供返回后打开，避免弹出其他页面或重复建档。
  String? _createdDocumentId;

  /// 创建成功后重载当前空间列表，使返回列表时能够看到新文档。
  int _documentListRevision = 0;
  String? _loadError;

  /// 从点击到编辑页退出期间持有，防止重复切换文档或同时创建。
  String? _openingDocumentId;

  /// 已有文档打开失败的展示消息，与创建恢复及位置读取的错误分开持有。
  String? _openError;

  /// 只认可用户对当前操作的核对勾选；操作ID变化后旧勾选不再生效。
  String? _reviewedOperationId;

  /// 读取位置并继承可选入口目标，迟到结果检查mounted。
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// 使位置请求失效；宿主继续拥有HTTP客户端及创建协调器。
  @override
  void dispose() {
    _positionRequest = null;
    super.dispose();
  }

  /// 判断[request]是否仍属于本页唯一有效的位置加载，关闭后总为false。
  bool _isCurrentPositionRequest(Object request) => mounted && identical(_positionRequest, request);

  /// 恢复记录读取成功即固定本次操作目标，再加载真实位置选项。
  /// 在途调用去重并同步显示加载状态；成功、失败及关闭均释放在途门禁。
  /// 回写核对令牌，迟到响应只补全有效请求的选项，不覆盖已绑定的恢复目标。
  Future<void> _load() async {
    if (!mounted || _positionRequest != null) return;
    final request = _positionRequest = Object();
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      await widget.coordinator.restore();
      if (!_isCurrentPositionRequest(request)) return;
      if (widget.coordinator.pending) {
        final target = widget.coordinator.operation!.target;
        setState(() => _selected = target);
      }
      final values = await widget.loadTargets();
      if (!_isCurrentPositionRequest(request)) return;
      final initial = _selected ?? widget.initialTarget;
      setState(() {
        _targets = [
          if (initial != null && !values.any((v) => v.id == initial.id)) initial,
          ...values,
        ];
        _selected = initial ?? _targets.firstOrNull;
        _loading = false;
        _loadError = null;
      });
    } catch (_) {
      if (_isCurrentPositionRequest(request)) {
        setState(() {
          _loading = false;
          _loadError = '位置加载失败，请重试';
        });
      }
    } finally {
      if (identical(_positionRequest, request)) _positionRequest = null;
    }
  }

  /// 执行新建或继续已有操作；继续前绑定记录位置，完成后仍保留相同展示目标。
  /// 关闭路由后不导航，协调器仍保留恢复结果。
  Future<void> _submit() async {
    if (_running || _openingDocumentId != null || widget.coordinator.busy) {
      return;
    }
    if (_createdDocumentId != null) {
      if (widget.onOpenDocument != null) {
        await _openListedDocument(_createdDocumentId!);
        return;
      }
      if (ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop(_createdDocumentId);
      }
      return;
    }
    final coordinator = widget.coordinator;
    setState(() {
      _running = true;
      _openError = null;
      if (coordinator.pending) _selected = coordinator.operation!.target;
    });
    final id = coordinator.pending
        ? await coordinator.resume()
        : _selected == null
        ? null
        : await coordinator.start(_selected!);
    if (!mounted) return;
    setState(() {
      _running = false;
      _createdDocumentId = id;
      if (id != null) _documentListRevision++;
    });
    if (id != null && ModalRoute.of(context)?.isCurrent == true) {
      if (widget.onOpenDocument != null) {
        await _openListedDocument(id);
      } else {
        Navigator.of(context).pop(id);
      }
    }
  }

  /// 结束用户已核对的未知操作；不导航、不自动新建，失败继续展示原恢复记录。
  Future<void> _finishReviewedOperation() async {
    if (_running ||
        _openingDocumentId != null ||
        widget.coordinator.busy ||
        _reviewedOperationId == null) {
      return;
    }
    final operationId = _reviewedOperationId!;
    setState(() => _running = true);
    await widget.coordinator.finishReviewedOperation(operationId);
    if (!mounted) return;
    setState(() {
      _running = false;
      _reviewedOperationId = null;
    });
  }

  /// 派发[documentId]的打开意图，重复回调直接忽略；失败留在列表，成功后保留位置。
  /// 宿主处理文档释放与导航；页面退出后不回写，已发起任务仍由宿主持有。
  Future<void> _openListedDocument(String documentId) async {
    final open = widget.onOpenDocument;
    if (!mounted ||
        open == null ||
        _running ||
        _openingDocumentId != null ||
        widget.coordinator.busy) {
      return;
    }
    setState(() {
      _openingDocumentId = documentId;
      _openError = null;
    });
    try {
      await open(documentId);
      if (!mounted) return;
      setState(() => _createdDocumentId = null);
    } catch (error) {
      if (!mounted) return;
      setState(() => _openError = error is FormatException ? error.message : '文档打开失败，请重试');
    } finally {
      if (mounted) setState(() => _openingDocumentId = null);
    }
  }

  /// 将[stage]映射为用户能理解的当前进度，不宣称远端持久化完成。
  String _progress(DocumentCreationStage? stage) => switch (stage) {
    DocumentCreationStage.creating => '正在创建文档…',
    DocumentCreationStage.shellCreated => '正在准备正文…',
    DocumentCreationStage.bodyPrepared || DocumentCreationStage.snapshotSending => '正在确认初始内容…',
    DocumentCreationStage.snapshotAccepted => '正在打开文档…',
    _ => '正在处理…',
  };

  /// 为[context]构建空间表单和惰性文档列表；右上角创建时冻结位置，返回仍保留进度。
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.coordinator,
    builder: (context, _) {
      final coordinator = widget.coordinator;
      final pending = coordinator.pending;
      final needsReview = coordinator.needsReview;
      final created = _createdDocumentId != null;
      final busy = _running || coordinator.busy || _openingDocumentId != null;
      final target = pending ? coordinator.operation!.target : _selected;
      final canCreate =
          !busy &&
          !needsReview &&
          (pending || created || (_selected != null && !_loading && _loadError == null));
      return Scaffold(
        appBar: AppBar(
          title: const Text('文档列表', maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            TextButton(
              key: const ValueKey('create-blank-document'),
              onPressed: canCreate ? _submit : null,
              child: Text(
                busy
                    ? '处理中'
                    : created
                    ? '打开文档'
                    : pending && !needsReview
                    ? '继续完成'
                    : '创建',
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          child: CustomScrollView(
            key: PageStorageKey('creation-documents-${target?.id ?? 'none'}'),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(24),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('新建到', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 12),
                      if (pending)
                        Text(coordinator.operation!.target.name)
                      else if (_loading)
                        const LinearProgressIndicator()
                      else if (_loadError != null) ...[
                        Text(_loadError!),
                        TextButton(
                          onPressed: busy || _loading ? null : _load,
                          child: const Text('重新加载位置'),
                        ),
                      ] else
                        DropdownButtonFormField<String>(
                          key: const ValueKey('creation-target'),
                          initialValue: _selected?.id,
                          isExpanded: true,
                          items: [
                            for (final target in _targets)
                              DropdownMenuItem(
                                value: target.id,
                                child: Text(
                                  target.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: busy || created
                              ? null
                              : (id) => setState(() {
                                  _selected = _targets.firstWhere((v) => v.id == id);
                                }),
                          decoration: const InputDecoration(border: OutlineInputBorder()),
                        ),
                      const SizedBox(height: 20),
                      const Text('创建后可在文档顶部修改标题。'),
                      if (pending) ...[
                        const SizedBox(height: 12),
                        Text(needsReview ? '创建结果不明，请先在文档库核对是否已创建。' : '上次创建尚未完成，将继续处理同一份文档。'),
                      ],
                      if (needsReview) ...[
                        const SizedBox(height: 12),
                        const Text('结束记录不会删除服务端文档。之后点击创建会新建另一份文档，不会重发此次请求。'),
                        Row(
                          children: [
                            Checkbox(
                              key: const ValueKey('creation-result-reviewed'),
                              value: _reviewedOperationId == coordinator.operation!.operationId,
                              onChanged: busy
                                  ? null
                                  : (checked) => setState(() {
                                      _reviewedOperationId = checked == true
                                          ? coordinator.operation!.operationId
                                          : null;
                                    }),
                            ),
                            const Expanded(child: Text('我已在文档库核对，结束此次记录')),
                          ],
                        ),
                      ],
                      if (coordinator.error != null && _openError == null) ...[
                        const SizedBox(height: 16),
                        Text(
                          coordinator.error!,
                          style: TextStyle(color: Theme.of(context).colorScheme.error),
                        ),
                      ],
                      if (_openError != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          _openError!,
                          key: const ValueKey('document-open-error'),
                          style: TextStyle(color: Theme.of(context).colorScheme.error),
                        ),
                      ],
                      const SizedBox(height: 24),
                      if (needsReview)
                        FilledButton(
                          key: const ValueKey('finish-reviewed-creation'),
                          onPressed:
                              busy || _reviewedOperationId != coordinator.operation!.operationId
                              ? null
                              : _finishReviewedOperation,
                          child: const Text('结束此次记录'),
                        ),
                      if (busy)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            _openingDocumentId != null
                                ? '正在打开文档…'
                                : '${_progress(coordinator.operation?.stage)} 返回后仍会保留创建进度，请勿重复创建。',
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (target != null)
                DocumentSpaceList(
                  key: ValueKey('space-documents-${target.id}-$_documentListRevision'),
                  target: target,
                  loadPage: widget.loadDocuments,
                  onOpenDocument: widget.onOpenDocument == null
                      ? null
                      : (item) => unawaited(_openListedDocument(item.id)),
                  enabled: !busy,
                  openingDocumentId: _openingDocumentId,
                ),
            ],
          ),
        ),
      );
    },
  );
}
