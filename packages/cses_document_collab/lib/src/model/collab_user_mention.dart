import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_inline_formula.dart';

/// 内存投影的用户及三类实体显示名；仅 U+FFFC 带此属性时恢复 mention 对象。
const collabInlineMentionAttribute = 'cses_inline_mention';

/// 内存投影的用户稳定 ID，不作为普通文字格式写入 Y.Text。
const collabMentionIdAttribute = 'cses_mention_id';

/// 内存中的实体类型；缺省是历史用户投影，meeting/task/doc使用各自展示与交互。
const collabMentionTypeAttribute = 'cses_mention_type';

/// 四类提及原始属性JSON快照，用于宿主点击事件和对象历史恢复，不作为普通文字格式。
const collabMentionAttributesAttribute = 'cses_mention_attributes';

/// 宿主提供的人员快照；正文只保存 [id] 和 [name]，不持有资源。
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// const person = CollabMentionUser(id: 'u1', name: '张三');
/// ```
final class CollabMentionUser {
  /// [id] 为真实用户ID，[name] 为显示名，[avatarUrl] 为可选头像URL。
  /// [department] 与 [position] 为可选部门/职位，仅供本地展示。
  const CollabMentionUser({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.department,
    this.position,
  });

  /// 必填稳定用户ID，非空且写入最多512个UTF-8字节。
  final String id;

  /// 必填显示名，写入最多20000个UTF-16单元。
  final String name;

  /// 可选宿主头像URL，不写正文；交给宿主头像构建器解释，null时由宿主决定默认地址/占位。
  final String? avatarUrl;

  /// 可选部门名称，不写正文。
  final String? department;

  /// 可选职位名称，不写正文。
  final String? position;
}

/// 宿主选择器或详情页复用的人员查询端口；协同编辑器不直接读取目录。
/// 实现方持有HTTP/账号资源，调用方不关闭它们，失败须抛出异常。
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// class Directory implements CollabMentionDirectory {
///   @override
///   Future<List<CollabMentionUser>> search(String keyword) async =>
///       [const CollabMentionUser(id: 'u1', name: '张三')]
///           .where((u) => u.name.contains(keyword)).toList();
///   @override
///   Future<CollabMentionUser?> load(String userId) async =>
///       userId == 'u1' ? const CollabMentionUser(id: 'u1', name: '张三') : null;
/// }
/// Future<List<CollabMentionUser>> query() => Directory().search('张');
/// ```
abstract interface class CollabMentionDirectory {
  /// 搜索当前企业用户，[keyword] 为空返回初始列表；失败抛异常。
  /// 宿主校验账号/企业，界面忽略关闭或过期的异步结果。
  Future<List<CollabMentionUser>> search(String keyword);

  /// 读取稳定 [userId] 的部门/职位；不存在返回null，失败抛异常。
  Future<CollabMentionUser?> load(String userId);
}

/// 保存稳定用户身份与文字，拒绝迟到操作另一位用户。
/// ```dart
/// import 'package:cses_document_collab/src/model/collab_user_mention.dart';
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// final state = EditorState.blank();
/// final target = CollabUserMentionTarget.capture(state.document.first!, 0);
/// state.dispose();
/// ```
final class CollabUserMentionTarget {
  /// [blockId] 是稳定块ID，[offset] 为UTF-16位置，[text] 为打开时正文，
  /// [name] 与 [userId] 为打开时身份，用于冲突检测。
  const CollabUserMentionTarget._(
    this.blockId,
    this.offset,
    this.text,
    this.name,
    this.userId,
  );

  /// 协同块稳定ID。
  final String blockId;

  /// 对象的UTF-16位置。
  final int offset;

  /// 打开时的正文定位文字。
  final String text;

  /// 打开时的显示名。
  final String name;

  /// 打开时的用户ID。
  final String userId;

  /// 从借用 [node] 的UTF-16 [offset] 捕获用户；其他实体、非对象或缺身份返回null。
  static CollabUserMentionTarget? capture(Node node, int offset) {
    if (offset < 0 || offset >= (node.delta?.length ?? 0)) return null;
    final operation = node.delta!.slice(offset, offset + 1).first;
    final name = operation.attributes?[collabInlineMentionAttribute];
    final id = operation.attributes?[collabMentionIdAttribute];
    if (operation is! TextInsert ||
        operation.text != collabInlineFormulaCharacter ||
        const {
          'meeting',
          'task',
          'doc',
        }.contains(operation.attributes?[collabMentionTypeAttribute]) ||
        name is! String ||
        id is! String ||
        id.isEmpty) {
      return null;
    }
    return CollabUserMentionTarget._(
      node.attributes['cses_collab_block_id'] as String? ?? node.id,
      offset,
      node.delta!.toPlainText(),
      name,
      id,
    );
  }

  /// 在借用 [state] 中重定位；文字/用户变化、关闭或删除返回null。
  Node? resolve(EditorState state) {
    final node = findCollabInlineTextNode(state, blockId);
    if (node == null || node.delta?.toPlainText() != text) return null;
    final current = capture(node, offset);
    return current?.name == name && current?.userId == userId ? node : null;
  }
}

/// 在借用 [state] 的同块 [selection] 插入真实 [user] 并追加空格，返回对象后的光标。
/// 范围被替换；代码块/只读/无效身份返回null，不恢复焦点；异常透传。
Future<Selection?> insertCollabUserMention(
  EditorState state,
  Selection selection,
  CollabMentionUser user,
) async {
  if (state.isDisposed ||
      !state.editable ||
      !selection.isSingle ||
      user.id.isEmpty ||
      utf8.encode(user.id).length > 512 ||
      user.name.isEmpty ||
      user.name.length > 20000) {
    return null;
  }
  final normalized = selection.normalized;
  final node = state.getNodeAtPath(normalized.start.path);
  final delta = node?.delta;
  final start = normalized.start.offset;
  final end = normalized.end.offset;
  if (node == null ||
      delta == null ||
      node.type == 'code' ||
      start < 0 ||
      end < start ||
      end > delta.length) {
    return null;
  }
  final after = Delta()
    ..insert(
      collabInlineFormulaCharacter,
      attributes: {
        collabInlineMentionAttribute: user.name,
        collabMentionIdAttribute: user.id,
        collabMentionAttributesAttribute: jsonEncode({
          'mentionType': 'user',
          'mentionId': user.id,
        }),
      },
    )
    ..insert(' ');
  await applyCollabInlineCommand(
    state,
    node,
    start,
    delta.slice(start, end),
    after,
  );
  return Selection.single(path: node.path, startOffset: start + 2);
}

/// 删除借用 [state] 的稳定 [target]，保留周围文字；只读/目标变化返回false。
/// 生成独立历史，按块ID重定位并拒绝覆盖远端修改；异常透传。
Future<bool> deleteCollabUserMention(
  EditorState state,
  CollabUserMentionTarget target,
) async {
  if (state.isDisposed || !state.editable) return false;
  final node = target.resolve(state);
  if (node == null) return false;
  await applyCollabInlineCommand(
    state,
    node,
    target.offset,
    node.delta!.slice(target.offset, target.offset + 1),
    Delta(),
  );
  return true;
}
