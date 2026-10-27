import 'package:cses_document_collab/src/model/collab_document_config.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/model/prepared_document.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/collab_runtime.dart';

/// 正式新文档的短生命周期正文准备入口，不创建编辑视图或协同会话。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// Future<PreparedDocument> prepare(CollabDocumentConfig config) async {
///   // 宿主已完成HTTP建档并持久化以下稳定参数，旧控制器已关闭。
///   return DocumentBootstrapper.prepareBlank(config: config,
///     operationId: 'creation-operation', paragraphId: 'initial-paragraph',
///     createdAt: DateTime.fromMillisecondsSinceEpoch(1792584000000));
/// }
/// ```
abstract final class DocumentBootstrapper {
  /// 为已建档的[config]落盘空正文；调用方负责确认业务建档成功。
  /// [operationId]、[paragraphId]及毫秒精度的[createdAt]必须先由宿主持久化，
  /// 重试保持相同值。占用中的原生引擎、草稿配置或既有不同正文拒绝初始化。
  /// Future完成表示本地增量与标记已提交；不表示HTTP或远端保存。
  /// 临时原生资源由本方法释放，宿主随后可创建正式控制器恢复同一分区。
  static Future<PreparedDocument> prepareBlank({
    required CollabDocumentConfig config,
    required String operationId,
    required String paragraphId,
    required DateTime createdAt,
  }) async {
    config.validate();
    if (!config.isFormal) throw const FormatException('只有已建档的正式文档可以初始化');
    final owner = Object();
    CollabRuntime.acquire(owner, const CollabHostServices());
    try {
      await CollabRuntime.initialize();
      return PreparedDocument.fromSnapshotJson(
        native.prepareCsesDocument(
          documentId: config.documentId,
          cacheDocumentId: config.cacheDocumentId,
          databasePath: config.databasePath,
          operationId: operationId,
          paragraphId: paragraphId,
          createdTime: createdAt.millisecondsSinceEpoch.toDouble(),
        ),
      );
    } finally {
      CollabRuntime.release(owner);
    }
  }
}
