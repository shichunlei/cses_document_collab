import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_inline_formula.dart';
import 'package:cses_document_collab/src/model/collab_meeting.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/model/collab_user_mention.dart';

/// 桌面会议KR列表的正式void类型，业务内容不保存在文档内。
const collabKrType = 'kr-list';

/// 一条主题内的KR展示快照，不持有网络资源。
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// const kr = CollabKrItem(id: 'k1', title: '完成上线', rank: 1);
/// ```
final class CollabKrItem {
  /// [id]为稳定业务ID，[title]为正文，[rank]为主题内从1开始的名次。
  /// [authorId]/[authorName]为可选作者身份；[votes]为可选非负票数。
  const CollabKrItem({
    required this.id,
    required this.title,
    required this.rank,
    this.authorId,
    this.authorName,
    this.votes,
  });

  /// 必填稳定业务ID，用于分页去重。
  final String id;

  /// 必填KR内容，显示时允许换行。
  final String title;

  /// 必填主题内名次，从1开始。
  final int rank;

  /// 可选作者ID，和姓名同时存在时转为用户提及。
  final String? authorId;

  /// 可选作者姓名。
  final String? authorName;

  /// 可选非负票数，null不展示。
  final int? votes;
}

/// 一个KR主题的首屏及分页结果；只作为本地展示状态。
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// const topic = CollabKrTopic(id: 't1', title: '交付', total: 0, items: []);
/// ```
final class CollabKrTopic {
  /// [id]为分页主题ID，[title]为标题，[total]为非负总数，[items]为本页条目。
  /// 调用方不得在返回后修改[items]。
  const CollabKrTopic({
    required this.id,
    required this.title,
    required this.total,
    required this.items,
  });

  /// 必填稳定主题ID。
  final String id;

  /// 必填主题标题。
  final String title;

  /// 必填主题内KR总数，不写文档。
  final int total;

  /// 宿主返回的只读条目，不转移网络资源所有权。
  final List<CollabKrItem> items;
}

/// 宿主拥有认证和请求的KR查询端口；编辑器只借用，失败抛异常以允许重试。
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// class EmptyKrService implements CollabKrService {
///   Future<List<CollabKrTopic>> loadTopics(String meetingId) async => [];
///   Future<List<CollabKrItem>> loadMore(String meetingId, String topicId, int offset) async => [];
/// }
/// final services = CollabHostServices(kr: EmptyKrService());
/// ```
abstract interface class CollabKrService {
  /// 加载[meetingId]的主题及首屏；空列表表示暂无KR，会议删除/无权限应抛异常。
  Future<List<CollabKrTopic>> loadTopics(String meetingId);

  /// 从已加载条数[offset]续拉[meetingId]中[topicId]的下一页；空列表表示已到底。
  Future<List<CollabKrItem>> loadMore(
    String meetingId,
    String topicId,
    int offset,
  );
}

/// 从借用[attributes]读取KR的会议引用，不产生业务内容或共享属性补丁。
CollabResource readCollabKr(Map<String, dynamic> attributes) {
  final raw = attributes[collabResourceAttribute];
  return raw is Map
      ? CollabResource.fromJson(Map<String, dynamic>.from(raw))
      : const CollabResource();
}

/// 将借用[editor]内[source]关联的会议[meetingId]收集为后置KR块。
/// 关闭、只读、已分离、非会议及身份变化返回false；写入独立历史，不创建业务KR。
Future<bool> collectCollabKr(
  EditorState editor,
  Node source,
  String meetingId,
) async {
  if (editor.isDisposed ||
      !editor.editable ||
      source.parent == null ||
      source.type != 'meeting' ||
      !const {'page', 'callout'}.contains(source.parent?.type)) {
    return false;
  }
  if (!identical(editor.getNodeAtPath(source.path), source) ||
      CollabMeeting.readAttributes(source.attributes).string('meetingId') !=
          meetingId) {
    return false;
  }
  final node = Node(
    type: collabKrType,
    attributes: {
      collabResourceAttribute: CollabResource.fromValues({
        'meetingId': meetingId,
      }).toJson(),
    },
  );
  node.updateAttributes({'cses_collab_block_id': node.id});
  if (editor.undoManager.undoStack.isNonEmpty) {
    editor.undoManager.undoStack.last.seal();
  }
  await editor.apply(
    editor.transaction..insertNode(source.path.next, node, deepCopy: false),
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
  return true;
}

/// 将借用[editor]内[source]后的KR[item]转为未勾选待办，作者身份完整时附用户提及。
/// 关闭、只读、源分离或数据超过正文限制返回false；同一事务支持独立撤销，不修改KR业务。
Future<bool> convertCollabKr(
  EditorState editor,
  Node source,
  CollabKrItem item,
) async {
  if (editor.isDisposed ||
      !editor.editable ||
      source.parent == null ||
      source.type != collabKrType ||
      !identical(editor.getNodeAtPath(source.path), source) ||
      item.title.length > 20000 ||
      (item.authorName?.length ?? 0) > 20000 ||
      utf8.encode(item.authorId ?? '').length > 512 ||
      !const {'page', 'callout'}.contains(source.parent?.type)) {
    return false;
  }
  final delta = Delta();
  if (item.authorId?.isNotEmpty == true &&
      item.authorName?.isNotEmpty == true) {
    delta.insert(
      collabInlineFormulaCharacter,
      attributes: {
        collabInlineMentionAttribute: item.authorName,
        collabMentionIdAttribute: item.authorId,
        collabMentionTypeAttribute: 'user',
      },
    );
    delta.insert(' ');
  }
  delta.insert(item.title);
  final node = todoListNode(checked: false, delta: delta);
  node.updateAttributes({'cses_collab_block_id': node.id});
  if (editor.undoManager.undoStack.isNonEmpty) {
    editor.undoManager.undoStack.last.seal();
  }
  await editor.apply(
    editor.transaction..insertNode(source.path.next, node, deepCopy: false),
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
  return true;
}
