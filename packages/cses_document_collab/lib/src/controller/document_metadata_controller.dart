import 'package:flutter/foundation.dart';
import 'package:cses_document_collab/src/model/document_metadata.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';

/// 独立持有正式头部读写状态；只在业务ACK后更新，不改正文或正文历史。
/// 借用宿主端口，合并并发刷新并隔离迟到响应；创建方关闭并等待已发出的业务请求。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// Future<void> editHeader(DocumentMetadataService service) async {
///   final header = DocumentMetadataController(documentId: 'doc', service: service, canEdit: () => true);
///   try {
///     await header.refresh();
///     await header.save(const DocumentMetadataPatch.rename('新标题'));
///   } finally {
///     await header.close();
///   }
/// }
/// ```
class DocumentMetadataController extends ChangeNotifier {
  /// [documentId] 是固定正式ID；[service] 借自宿主，服务失败由状态和诊断回调呈现。
  /// [canEdit] 在操作时读取宿主权限；[services] 默认使用标准诊断实现，属于借用资源。
  DocumentMetadataController({
    required this.documentId,
    required this.service,
    required this.canEdit,
    this.services = const CollabHostServices(),
  });

  /// 固定正式文档ID，不跨文档或账号复用。
  final String documentId;

  /// 借用的业务端口；本控制器不释放宿主服务。
  final DocumentMetadataService service;

  /// 动态宿主编辑门禁；false时阻止提交，不影响读取。
  final bool Function() canEdit;

  /// 借用的诊断端口；业务失败报告原异常和堆栈。
  final CollabHostServices services;

  /// 最近成功读取或保存的业务快照；首次读取成功前为null。
  DocumentMetadata? value;

  /// 可展示的失败原因；null表示无当前错误，成功操作会清除。
  String? error;

  /// 当前是否等待业务读取；保存会使旧读取失效。
  bool loading = false;

  /// 当前是否等待业务写入；期间禁止重复写入。
  bool saving = false;
  bool _disposed = false;
  int _revision = 0;
  Future<void>? _reading;
  Future<bool>? _writing;

  /// 综合宿主、业务、存活及提交状态的改名门禁；不发送请求。
  bool get canRename =>
      !_disposed && !saving && canEdit() && value?.canRename == true;

  /// 综合宿主、业务、存活及提交状态的外观门禁；不发送请求。
  bool get canChangeAppearance =>
      !_disposed && !saving && canEdit() && value?.canChangeAppearance == true;

  /// 多次刷新共享进行中的读取；保存期间不发读取，迟到响应不能覆盖新保存结果。
  Future<void> refresh() {
    if (_disposed || saving) return Future.value();
    return _reading ??= _load().whenComplete(() => _reading = null);
  }

  /// 读取固定文档并通知监听者；按修订序号忽略迟到结果，失败保留旧值并记录诊断。
  Future<void> _load() async {
    final revision = ++_revision;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final next = await service.load(documentId);
      if (next.id != documentId) throw const FormatException('文档头部身份不匹配');
      if (!_disposed && revision == _revision) value = next;
    } catch (failure, stack) {
      if (!_disposed && revision == _revision) {
        error = '头部加载失败，请重试';
        services.report('文档头部加载失败', failure, stack, 'DocMetadata');
      }
    } finally {
      if (!_disposed && revision == _revision) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// 提交 [patch] 前重新检查宿主与业务权限；重复点击、销毁或只读不发送请求。
  /// 成功更新当前字段，失败保留旧值并返回 false；关闭等待已发出的业务写入。
  Future<bool> save(DocumentMetadataPatch patch) {
    if (patch.name != null ? !canRename : !canChangeAppearance) {
      return Future.value(false);
    }
    if (patch.name != null &&
        (patch.name!.trim().isEmpty || patch.name!.length > 100)) {
      error = '标题需为 1～100 个字符';
      notifyListeners();
      return Future.value(false);
    }
    return _writing = _save(patch).whenComplete(() => _writing = null);
  }

  /// 写入已通过门禁的 [patch]；仅ACK后合并快照，失败或销毁返回false，结束时释放提交状态。
  Future<bool> _save(DocumentMetadataPatch patch) async {
    ++_revision;
    loading = false;
    saving = true;
    error = null;
    notifyListeners();
    try {
      await service.update(documentId, patch);
      if (_disposed) return false;
      value = value?.apply(patch);
      return true;
    } catch (failure, stack) {
      if (!_disposed) {
        error = '头部保存失败，请重试';
        services.report('文档头部保存失败', failure, stack, 'DocMetadata');
      }
      return false;
    } finally {
      if (!_disposed) {
        saving = false;
        notifyListeners();
      }
    }
  }

  /// 宿主权限变化立即通知头部界面，弹窗提交时也会重新检查权限。
  void permissionsChanged() {
    if (!_disposed) notifyListeners();
  }

  /// 先禁止迟到结果，再等待读写结束；服务属于宿主，不由本实例关闭。
  Future<void> close() async {
    dispose();
    await _reading;
    await _writing;
  }

  /// 同步终止通知和新操作，旧响应不再写回；不释放宿主端口，等待请求请调用 [close]。
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_revision;
    super.dispose();
  }
}
