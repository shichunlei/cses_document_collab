import 'package:cses_document_collab/cses_document_collab.dart' show PreparedDocument;
import 'document_creation_operation.dart';

/// 初始HTTP快照的回读分类；missing不能证明先前请求不会迟到。
enum InitialSnapshotState {
  /// 未查到初始根，继续等待核对，不能盲目重发。
  missing,

  /// 与本次初始化快照完全匹配。
  matches,

  /// 已有不同正文，必须进入恢复处理。
  different,
}

/// 创建编排借用的已鉴权业务端口，具体Common依赖留在宿主实现。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_api.dart';
/// Future<void> inspectTargets(DocumentCreationApi api) async {
///   api.checkSession();
///   final targets = await api.loadTargets();
///   print(targets.length);
/// }
/// ```
abstract interface class DocumentCreationApi {
  /// 同步校验绑定账号、企业及会话；失效时抛错且不发后续请求。
  void checkSession();

  /// 读取真实个人/企业空间，必要时按服务端契约初始化个人空间。
  Future<List<DocumentCreationTarget>> loadTargets();

  /// 读取[target]的createChild能力；未授权或读取失败抛错。
  Future<void> verifyTarget(DocumentCreationTarget target);

  /// 核对[documentId]仍存在且本账号可访问；失败抛错，核验前不释放当前文档。
  /// 只读取正式文档详情，不创建业务记录或初始化正文。
  Future<void> verifyDocumentToOpen(String documentId);

  /// 在[target]下创建空名文本记录。成功返回ID，即使响应期间账号已切换也让
  /// 协调器先记录该ID；下一步由checkSession阻止旧操作继续。
  Future<String> createBlank(DocumentCreationTarget target);

  /// 保存[prepared]的初始快照并核验业务结果；不保证PaaS正文落库。
  Future<void> writeInitial(PreparedDocument prepared);

  /// 回读[prepared]对应初始块，判断前次快照写入是否已确认。
  Future<InitialSnapshotState> readInitial(PreparedDocument prepared);
}
