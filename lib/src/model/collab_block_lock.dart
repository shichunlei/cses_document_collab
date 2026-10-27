/// 宿主额外解锁授权的上下文；普通锁本人解锁不调用额外授权来限制本人。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final services = CollabHostServices(canUnlockBlock: (lock) => false);
/// ```
final class CollabBlockUnlockContext {
  /// [documentId]、[blockId]标识目标，[currentUserId]为当前账号，
  /// [ownerId]为锁的创建者，[template]说明是否为模板锁。
  const CollabBlockUnlockContext({
    required this.documentId,
    required this.blockId,
    required this.currentUserId,
    required this.ownerId,
    required this.template,
  });

  /// 当前正式文档身份，不是本机缓存键。
  final String documentId;

  /// 显式加锁的块身份。
  final String blockId;

  /// 当前宿主账号的稳定ID。
  final String currentUserId;

  /// 原始meta.lock用户ID，不进行姓名解析或认证。
  final String ownerId;

  /// 模板锁始终需要宿主额外授权，不能仅凭创建者身份解锁。
  final bool template;
}

/// 原生完整块图派生的锁状态，不作为正文快照的可写属性。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// const state = CollabBlockLockState(blockId: 'p1', sourceId: 'p1', ownerId: 'u1');
/// assert(state.locked);
/// ```
final class CollabBlockLockState {
  /// [blockId]为当前块，[sourceId]为自身/最近加锁祖先，null表示未锁。
  /// [ownerId]为有效锁原始用户ID，[template]默认false，[containsLock]包含自身和隐藏子树。
  const CollabBlockLockState({
    required this.blockId,
    this.sourceId,
    this.ownerId,
    this.template = false,
    this.containsLock = false,
  });

  /// 当前稳定块身份。
  final String blockId;

  /// 有效锁来源；null表示自身不只读。
  final String? sourceId;

  /// 有效锁的所有者；无锁时为null。
  final String? ownerId;

  /// 是否为模板锁；未知lockKind按普通锁处理。
  final bool template;

  /// 子树是否含显式锁；阻止连带删除/移动。
  final bool containsLock;

  /// 当前块是否继承或显式持有锁。
  bool get locked => sourceId != null;

  /// 是否由当前块自身显式加锁。
  bool get explicit => sourceId == blockId;

  /// 比较借用的[other]是否拥有同一权限状态，不涉及正文。
  @override
  bool operator ==(Object other) =>
      other is CollabBlockLockState &&
      blockId == other.blockId &&
      sourceId == other.sourceId &&
      ownerId == other.ownerId &&
      template == other.template &&
      containsLock == other.containsLock;

  /// 与权限状态相同的哈希值。
  @override
  int get hashCode => Object.hash(blockId, sourceId, ownerId, template, containsLock);
}
