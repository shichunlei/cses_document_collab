/// 文档点赞成员的只读资料；头像加载与鉴权由宿主头像构建器负责。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// const member = CollabDocumentLikeMember(userId: 'u1', name: '张三');
/// ```
class CollabDocumentLikeMember {
  /// [userId]是稳定人员ID；[name]是显示名；[avatarUrl]是可选宿主头像地址。
  const CollabDocumentLikeMember({
    required this.userId,
    required this.name,
    this.avatarUrl,
  });

  /// 必填稳定人员ID，用于头像和成员身份识别。
  final String userId;

  /// 必填显示名，空值时界面使用通用人员提示。
  final String name;

  /// 可选头像地址，null交给宿主头像构建器决定展示。
  final String? avatarUrl;
}

/// 宿主确认的点赞状态，成员列表复制为只读快照，不写入协同正文。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final likes = CollabDocumentLikes(isLiked: true, members: [
///   const CollabDocumentLikeMember(userId: 'u1', name: '张三'),
/// ]);
/// ```
class CollabDocumentLikes {
  /// [isLiked]表示当前登录用户是否已赞，默认false。
  /// [members]为完整点赞成员列表，默认空；由宿主保证身份唯一和状态一致。
  CollabDocumentLikes({
    this.isLiked = false,
    List<CollabDocumentLikeMember> members = const [],
  }) : members = List.unmodifiable(members);

  /// 当前用户是否已点赞；再次点击时宿主应据此执行取消点赞。
  final bool isLiked;

  /// 按宿主顺序排列的完整点赞成员只读快照。
  final List<CollabDocumentLikeMember> members;
}

/// 文末互动业务快照；由宿主加载，点赞与评论回调分别更新对应字段。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final feedback = CollabDocumentFeedback(
///   likes: CollabDocumentLikes(), commentCount: 3,
/// );
/// ```
class CollabDocumentFeedback {
  /// [likes]为必填点赞快照；[commentCount]为非负评论数量，默认0。
  /// [commentCount]为负数时抛出RangeError，不接受无效业务结果。
  CollabDocumentFeedback({required this.likes, int commentCount = 0})
    : commentCount = RangeError.checkNotNegative(commentCount, 'commentCount');

  /// 完整点赞成员与当前用户状态。
  final CollabDocumentLikes likes;

  /// 全文评论数量，非负，评论内容和页面由宿主持有。
  final int commentCount;
}
