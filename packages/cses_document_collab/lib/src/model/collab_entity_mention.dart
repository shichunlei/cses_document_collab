import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_inline_formula.dart';
import 'package:cses_document_collab/src/model/collab_meeting.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/model/collab_task_card.dart';
import 'package:cses_document_collab/src/model/collab_user_mention.dart';

/// 实体原子操作的稳定身份，连同原始属性检测远端变化；不持有编辑器资源。
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/model/collab_entity_mention.dart';
/// final state = EditorState.blank();
/// final target = CollabEntityMentionTarget.capture(state.document.first!, 0);
/// if (target != null) await deleteCollabEntityMention(state, target);
/// state.dispose();
/// ```
final class CollabEntityMentionTarget {
  /// [blockId] 为块身份，[offset] 为UTF-16位置，[text] 为定位正文；
  /// [name]/[entityId] 为实体显示名与身份，[entityType] 为meeting/task/doc类型，[atomJson] 为冻结的完整原子属性快照。
  const CollabEntityMentionTarget._(
    this.blockId,
    this.offset,
    this.text,
    this.name,
    this.entityId,
    this.entityType,
    String atomJson,
  ) : _atomJson = atomJson;

  /// 所在块的稳定身份，不持有可能被重排替换的Node。
  final String blockId;

  /// 原子占据的UTF-16位置。
  final int offset;

  /// 打开时正文，用于拒绝过期位置。
  final String text;

  /// 共享正文保存的原始实体名称，不代表业务服务中的实时标题。
  final String name;

  /// 原始实体稳定ID，不作为人员身份读取头像。
  final String entityId;

  /// meeting/task/doc中的明确类型，不与同ID用户混同。
  final String entityType;

  /// 冻结完整属性，远端名称、状态或编号变化后旧删除/历史不得覆盖它们。
  final String _atomJson;

  /// 捕获借用 [node] 中UTF-16 [offset] 的实体；普通字符、其他实体或缺身份返回null。
  static CollabEntityMentionTarget? capture(Node node, int offset) {
    final delta = node.delta;
    if (delta == null || offset < 0 || offset >= delta.length) return null;
    final atom = delta.slice(offset, offset + 1);
    final operation = atom.first;
    final attrs = operation.attributes;
    final name = attrs?[collabInlineMentionAttribute];
    final id = attrs?[collabMentionIdAttribute];
    if (operation is! TextInsert ||
        operation.text != collabInlineFormulaCharacter ||
        !const {
          'meeting',
          'task',
          'doc',
        }.contains(attrs?[collabMentionTypeAttribute]) ||
        attrs?[collabMentionAttributesAttribute] is! String ||
        name is! String ||
        id is! String ||
        id.isEmpty) {
      return null;
    }
    return CollabEntityMentionTarget._(
      node.attributes['cses_collab_block_id'] as String? ?? node.id,
      offset,
      delta.toPlainText(),
      name,
      id,
      attrs![collabMentionTypeAttribute] as String,
      jsonEncode(atom.toJson()),
    );
  }

  /// 在借用 [state] 中按块ID重定位；正文或完整原子变化、删除、关闭时返回null。
  Node? resolve(EditorState state) {
    final node = findCollabInlineTextNode(state, blockId);
    if (node == null || node.delta!.toPlainText() != text) return null;
    final current = capture(node, offset);
    return current?._atomJson == _atomJson ? node : null;
  }
}

/// 删除借用 [state] 中稳定 [target] 的一个实体提及，不改变实体业务数据。
/// 只读、关闭或远端变化返回false；成功生成独立历史，撤销恢复完整实体属性；异常透传。
Future<bool> deleteCollabEntityMention(
  EditorState state,
  CollabEntityMentionTarget target,
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

/// 将借用[state]中的稳定[target]转换为正式会议/任务卡片，不调用宿主详情回调。
/// 与桌面相同，原块保留前文，卡片插在原块之后，后文拆为新段落并保留其格式和对象。
/// 仅根/高亮/单列内的正文支持；关闭、只读、目标变化或引用超限返回false，事务异常透传。
/// 转换作为单独一项历史提交，不创建或更改业务实体；焦点由调用方管理。
Future<bool> convertCollabEntityMentionToCard(
  EditorState state,
  CollabEntityMentionTarget target,
) async {
  if (state.isDisposed || !state.editable) return false;
  final source = target.resolve(state);
  if (source == null ||
      source.children.isNotEmpty ||
      !const {'page', 'callout', 'column'}.contains(source.parent?.type)) {
    return false;
  }
  final properties = <String, dynamic>{
    if (target.entityType == 'meeting') 'meetingId': target.entityId,
    if (target.entityType == 'task') 'taskId': target.entityId,
    'title': target.name,
  };
  final resource = CollabResource.fromValues(properties);
  final Map<String, dynamic> attributes;
  if (target.entityType == 'meeting' && CollabMeeting.valid(properties)) {
    attributes = CollabMeeting.nodeAttributes(resource);
  } else if (target.entityType == 'task' && CollabTaskCard.valid(properties)) {
    attributes = {collabResourceAttribute: resource.toJson()};
  } else {
    return false;
  }
  final card = Node(type: target.entityType, attributes: attributes);
  card.updateAttributes({'cses_collab_block_id': card.id});
  final delta = source.delta!;
  final tail = delta.slice(target.offset + 1);
  final tailNode = tail.isNotEmpty ? paragraphNode(delta: tail) : null;
  tailNode?.updateAttributes({'cses_collab_block_id': tailNode.id});
  final transaction = state.transaction
    ..deleteText(source, target.offset, delta.length - target.offset)
    ..insertNodes(source.path.next, [card, ?tailNode], deepCopy: false);
  final command = <String, dynamic>{
    'sourceId': target.blockId,
    'sourceType': source.type,
    'before': delta.toJson(),
    'after': delta.slice(0, target.offset).toJson(),
    'cardId': card.id,
    'cardType': card.type,
    'properties': resource.properties,
    'tailId': tailNode?.id,
    'tail': tail.toJson(),
  };
  transaction.add(
    UpdateOperation(
      source.path,
      {
        collabMentionCardCommandAttribute: jsonEncode({
          ...command,
          'forward': true,
        }),
      },
      {
        collabMentionCardCommandAttribute: jsonEncode({
          ...command,
          'forward': false,
        }),
      },
    ),
  );
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  await state.apply(
    transaction,
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
  return true;
}

/// 转换历史的内存标记，不投影到原生共享属性。
const collabMentionCardCommandAttribute = 'cses_mention_card_command';

/// 在借用[state]中预检[transaction]的转换历史，按稳定源块身份重定位整组操作。
/// 前文、卡片引用或拆出后文已改变时原子拒绝该历史，避免撤销吞掉协同编辑。
/// 只处理包含转换标记的事务，不提交事务，也不修改共享模型。
void resolveCollabMentionCardCommand(
  EditorState state,
  Transaction transaction,
) {
  final marker = transaction.operations
      .whereType<UpdateOperation>()
      .where((op) => op.attributes[collabMentionCardCommandAttribute] is String)
      .firstOrNull;
  if (marker == null) return;
  final command =
      jsonDecode(marker.attributes[collabMentionCardCommandAttribute] as String)
          as Map;
  final source = findCollabInlineTextNode(state, command['sourceId'] as String);
  final forward = command['forward'] == true;
  var valid =
      !state.isDisposed &&
      state.editable &&
      source != null &&
      source.type == command['sourceType'] &&
      source.delta == Delta.fromJson(command[forward ? 'before' : 'after']);
  if (valid && !forward) {
    final card = source.next;
    valid =
        card != null &&
        card.type == command['cardType'] &&
        (card.attributes['cses_collab_block_id'] ?? card.id) ==
            command['cardId'] &&
        (card.type == collabMeetingType
                    ? CollabMeeting.readAttributes(card.attributes)
                    : CollabTaskCard.read(card.attributes))
                .properties ==
            command['properties'];
    if (valid && command['tailId'] != null) {
      final tail = card.next;
      valid =
          tail != null &&
          tail.type == 'paragraph' &&
          (tail.attributes['cses_collab_block_id'] ?? tail.id) ==
              command['tailId'] &&
          tail.delta == Delta.fromJson(command['tail']);
    }
  }
  if (!valid) {
    transaction.operations = [];
    transaction.afterSelection = state.selection;
    return;
  }
  final oldPath = marker.path;
  final path = source!.path;
  final shift = path.last - oldPath.last;
  transaction.operations = transaction.operations
      .map((op) => op.copyWith(path: [...path.parent, op.path.last + shift]))
      .toList();
}
