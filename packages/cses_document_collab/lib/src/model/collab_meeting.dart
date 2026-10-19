import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';

/// 桌面会议引用的 void 类型，不存正文或子块。
const collabMeetingType = 'meeting';

/// 可编辑的引用快照属性；业务详情不写入这些字段。
const collabMeetingKeys = {'meetingId', 'title', 'number'};

/// [property] 对应的独立历史字段，缺失和显式 null 分别保留。
String meetingPropertyAttribute(String property) => 'cses_meeting_$property';

/// 会议引用属性的编解码；不持有业务服务或编辑器。
/// ```dart
/// import 'package:cses_document_collab/src/model/collab_meeting.dart';
/// final valid = CollabMeeting.valid({'meetingId': 'm1', 'title': '周会'});
/// ```
abstract final class CollabMeeting {
  /// 校验 [values] 的引用身份及展示字段；ID最多512 UTF-8字节，标题2000、编号256 UTF-16单元。
  static bool valid(Map<String, dynamic> values) =>
      values['meetingId'] is String &&
      (values['meetingId'] as String).trim().isNotEmpty &&
      utf8.encode(values['meetingId'] as String).length <= 512 &&
      (values['title'] == null || values['title'] is String && (values['title'] as String).length <= 2000) &&
      (values['number'] == null || values['number'] is String && (values['number'] as String).length <= 256);

  /// 解码借用 [attributes]；仅 [edited] 中的字段生成补丁，不回放其他共享快照。
  static CollabResource readAttributes(Map<String, dynamic> attributes, {Set<String> edited = const {}}) {
    final raw = attributes[collabResourceAttribute];
    final resource = raw is Map ? CollabResource.fromJson(Map<String, dynamic>.from(raw)) : const CollabResource();
    final values = resource.values;
    final patch = <String, dynamic>{};
    for (final key in collabMeetingKeys) {
      final field = attributes[meetingPropertyAttribute(key)];
      if (field is! String) continue;
      final wrapper = jsonDecode(field) as Map;
      if (wrapper.containsKey('value')) {
        values[key] = wrapper['value'];
      } else {
        values.remove(key);
      }
      if (edited.contains(key)) patch[key] = wrapper;
    }
    return CollabResource.fromValues(values, edits: patch.isEmpty ? null : jsonEncode(patch));
  }

  /// 将 [resource] 拆为独立可撤销字段；不写权威共享数据。
  static Map<String, dynamic> nodeAttributes(CollabResource resource) => {
    collabResourceAttribute: resource.toJson(),
    for (final key in collabMeetingKeys) meetingPropertyAttribute(key): resource.field(key),
  };
}

/// 按稳定 [id] 在借用 [state] 中找会议，关闭或删除返回 null。
Node? findCollabMeeting(EditorState state, String id) {
  if (state.isDisposed) return null;

  /// 递归借用 [node]；不缓存可被协同投影替换的节点。
  Node? visit(Node node) {
    if (node.type == collabMeetingType && (node.attributes['cses_collab_block_id'] ?? node.id) == id) {
      return node;
    }
    for (final child in node.children) {
      final found = visit(child);
      if (found != null) return found;
    }
    return null;
  }

  return visit(state.document.root);
}

/// 在借用 [state] 中提交稳定 [id] 的引用 [values]，原子更新改变的字段。
/// [expected] 为打开时的完整引用属性JSON，变化时拒绝陈旧写入；只读/删除/非法返回false，事务失败透传。
Future<bool> changeCollabMeeting(
  EditorState state,
  String id,
  Map<String, dynamic> values, {
  required String expected,
}) async {
  if (state.isDisposed || !state.editable || !CollabMeeting.valid(values)) {
    return false;
  }
  final node = findCollabMeeting(state, id);
  if (node == null || CollabMeeting.readAttributes(node.attributes).properties != expected) {
    return false;
  }
  final before = <String, dynamic>{collabResourceTargetAttribute: id, collabResourceKindAttribute: collabMeetingType};
  final after = Map<String, dynamic>.from(before);
  final original = CollabMeeting.readAttributes(node.attributes).values;
  for (final key in collabMeetingKeys) {
    if (values[key] == original[key]) continue;
    final field = meetingPropertyAttribute(key);
    before[field] = node.attributes[field];
    after[field] = jsonEncode({'value': values[key]});
  }
  if (after.length == 2) return true;
  if (!state.undoManager.undoStack.isEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  await state.apply(
    state.transaction..add(UpdateOperation(node.path, after, before)),
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
  return true;
}

/// 在借用[state]中删除稳定块[id]，仅影响文档引用；[expected]为展示时的完整属性JSON。
/// 关闭/只读/目标已删或属性变化返回false；事务失败向调用方抛出。
/// 删除封闭独立撤销记录，父容器最后一项补空段落；不更新选区，调用方负责清除旧选区和输入焦点。
Future<bool> deleteCollabMeeting(EditorState state, String id, {required String expected}) async {
  if (state.isDisposed || !state.editable) return false;
  final node = findCollabMeeting(state, id);
  if (node == null || CollabMeeting.readAttributes(node.attributes).properties != expected) {
    return false;
  }
  final transaction = state.transaction..deleteNode(node);
  if (node.parent!.children.length == 1) {
    transaction.insertNode(node.path, paragraphNode());
  }
  if (!state.undoManager.undoStack.isEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  await state.apply(transaction, withUpdateSelection: false, skipHistoryDebounce: true);
  return true;
}

/// 在借用 [state] 的保存 [selection] 位置插入引用 [values]，返回后置段落光标。
/// 空正文被替换、非空保留；只支持根/高亮容器。非法或失效返回null，调用方恢复焦点，事务异常透传。
Future<Selection?> insertCollabMeeting(EditorState state, Selection selection, Map<String, dynamic> values) async {
  if (state.isDisposed || !state.editable || !CollabMeeting.valid(values) || selection.start.path.isEmpty) {
    return null;
  }
  final source = state.getNodeAtPath(selection.start.path);
  if (source == null || !const {'page', 'callout'}.contains(source.parent?.type)) {
    return null;
  }
  final meeting = Node(
    type: collabMeetingType,
    attributes: CollabMeeting.nodeAttributes(CollabResource.fromValues(values)),
  );
  meeting.updateAttributes({'cses_collab_block_id': meeting.id});
  final empty = source.delta?.toPlainText().isEmpty == true;
  final path = empty ? source.path : source.path.next;
  final transaction = state.transaction..insertNodes(path, [meeting, paragraphNode()], deepCopy: false);
  if (empty) transaction.deleteNode(source);
  if (!state.undoManager.undoStack.isEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  await state.apply(transaction, skipHistoryDebounce: true);
  return Selection.single(path: path.next, startOffset: 0);
}
