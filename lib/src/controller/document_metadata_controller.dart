import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/model/document_metadata.dart';
import 'package:flutter/foundation.dart';

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

  /// 可展示的失败原因；新操作会清除旧错误，冲突补读保留本轮写入失败提示。
  /// null 表示当前没有失败提示。
  String? error;

  /// 当前是否等待业务读取；保存会使旧读取失效。
  bool loading = false;

  /// 当前是否等待业务写入及其冲突补读；整轮结束前禁止重复写入。
  bool saving = false;
  bool _disposed = false;
  int _revision = 0;
  Future<void>? _reading;
  Future<bool>? _writing;

  /// 当前读取期间收到的逐字段补丁；每轮开始与结束时清空，不跨失败重放。
  final Map<String, DocumentMetadataPatch> _remoteDuringRead = {};

  /// 当前等待业务确认的单字段命令；补读期间清空，避免将读取事件视为写入冲突。
  DocumentMetadataPatch? _savingPatch;

  /// 当前写入期间收到同字段的不同值，需要在确认后重新读取权威快照。
  bool _writeConflict = false;

  /// 应用宿主已校验身份的 [patch]，仅当 [id] 是本控制器文档且仍存活时生效。
  /// 不发送请求、不要求本地编辑权限，也不进入正文历史；首载期间保留补丁。
  /// 保存期间若命中字段与本地提交不同，ACK后合并一次权威重读，不能比较HTTP和WS版本。
  void applyRemotePatch(String id, DocumentMetadataPatch patch) {
    if (_disposed || id != documentId) return;
    if (patch.name != null) {
      if (loading) _remoteDuringRead['name'] = patch;
      if (saving &&
          _savingPatch?.name != null &&
          _savingPatch!.name != patch.name) {
        _writeConflict = true;
      }
    } else if (patch.changesIcon) {
      if (loading) _remoteDuringRead['icon'] = patch;
      if (_savingPatch?.changesIcon == true &&
          !mapEquals(_savingPatch!.icon, patch.icon)) {
        _writeConflict = true;
      }
    } else if (patch.changesBanner) {
      if (loading) _remoteDuringRead['banner'] = patch;
      if (_savingPatch?.changesBanner == true &&
          !mapEquals(_savingPatch!.banner, patch.banner)) {
        _writeConflict = true;
      }
    }
    value = value?.apply(patch);
    notifyListeners();
  }

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

  /// 读取固定文档并通知监听者；补丁仅覆盖本轮读取，失败保留旧值并记录诊断。
  /// 按修订序号忽略迟到结果；保存的冲突补读直接调用本方法并保持写入互斥。
  /// [retainedError] 为本轮写入失败提示，非 null 时补读成功或失败均保留；
  /// 默认 null 表示独立读取或成功写入后的补读，读取失败展示加载错误。
  Future<void> _load({String? retainedError}) async {
    final revision = ++_revision;
    _remoteDuringRead.clear();
    loading = true;
    error = retainedError;
    notifyListeners();
    try {
      final next = await service.load(documentId);
      if (next.id != documentId) throw const FormatException('文档头部身份不匹配');
      if (!_disposed && revision == _revision) {
        value = next;
        for (final patch in _remoteDuringRead.values) {
          value = value!.apply(patch);
        }
        _remoteDuringRead.clear();
      }
    } catch (failure, stack) {
      if (!_disposed && revision == _revision) {
        error = retainedError ?? '头部加载失败，请重试';
        services.report('文档头部加载失败', failure, stack, 'DocMetadata');
      }
    } finally {
      if (!_disposed && revision == _revision) {
        _remoteDuringRead.clear();
        loading = false;
        notifyListeners();
      }
    }
  }

  /// 提交 [patch] 前重新检查宿主与业务权限；重复点击、销毁或只读不发送请求。
  /// [expectedName]可选，为改名草稿打开时的名称；不匹配拒绝覆盖远端新名。
  /// 成功更新当前字段，冲突时等待权威补读；写入失败返回 false 并保留失败提示，
  /// 补读仍可合并远端字段，但其成功不会清除本轮写入错误。
  /// 写入及补读共用互斥状态，关闭等待整轮请求结束。
  Future<bool> save(DocumentMetadataPatch patch, {String? expectedName}) {
    if (patch.name != null &&
        expectedName != null &&
        value?.name != expectedName) {
      error = '文档名称已由其他端修改，请重新打开后编辑';
      if (!_disposed) notifyListeners();
      return Future.value(false);
    }
    if (patch.name != null ? !canRename : !canChangeAppearance) {
      return Future.value(false);
    }
    if (patch.name != null &&
        (patch.name!.trim().isEmpty || patch.name!.length > 100)) {
      error = '标题需为 1～100 个字符';
      notifyListeners();
      return Future.value(false);
    }
    late final Future<bool> writing;
    writing = _save(patch).whenComplete(() {
      if (identical(_writing, writing)) _writing = null;
    });
    return _writing = writing;
  }

  /// 写入已通过门禁的 [patch]；仅ACK后合并快照，失败或销毁返回false。
  /// 同字段冲突在整轮提交锁内补读，结束时释放状态，关闭可等待所有在途业务请求。
  /// 写入失败提示优先于补读结果；写入已确认而补读失败时保留加载错误。
  Future<bool> _save(DocumentMetadataPatch patch) async {
    String? writeError;
    ++_revision;
    _remoteDuringRead.clear();
    _savingPatch = patch;
    _writeConflict = false;
    loading = false;
    saving = true;
    error = null;
    notifyListeners();
    try {
      await service.update(documentId, patch);
      if (_disposed) return false;
      if (!_writeConflict) value = value?.apply(patch);
    } catch (failure, stack) {
      if (!_disposed) {
        error = writeError = '头部保存失败，请重试';
        services.report('文档头部保存失败', failure, stack, 'DocMetadata');
      }
      return false;
    } finally {
      _savingPatch = null;
      try {
        if (!_disposed && _writeConflict) {
          await _reading;
          if (!_disposed) await _load(retainedError: writeError);
        }
      } finally {
        _writeConflict = false;
        if (!_disposed) {
          saving = false;
          notifyListeners();
        }
      }
    }
    return !_disposed;
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
